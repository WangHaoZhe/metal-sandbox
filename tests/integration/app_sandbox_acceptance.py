#!/usr/bin/env python3
"""Trusted native App Sandbox checks. Never falls back to an unsigned/bare-host runner.

Run from a normal terminal on the target Mac, after `swift build`.
Only owned app bundles, canaries and loopback connections are used. A shared
per-UID lease prevents overlap with metal-sandboxd. An uncertain execution keeps
its recovery marker; the script never automatically acknowledges GPU recovery.
"""
import argparse
import base64
import errno
import fcntl
import json
import os
from pathlib import Path
import platform
import select
import shlex
import socket
import struct
import subprocess
import time
import uuid
from package_sandbox_host import assemble, sign_inherited_executable

LIMIT = 16 * 1024 * 1024


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


class Host:
    def __init__(self, app, output, marker):
        self.app = app
        self.marker = marker
        self.log = (output / (app.stem + "_stderr.log")).open("wb")
        self.process = subprocess.Popen([str(app / "Contents/MacOS/sandbox-host")],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"},
                                        bufsize=0, close_fds=True)
        os.set_blocking(self.process.stdin.fileno(), False)
        os.set_blocking(self.process.stdout.fileno(), False)

    def call(self, operation, timeout=15, **fields):
        request = {"id": str(uuid.uuid4()), "operation": operation, **fields}
        body = json.dumps(request).encode()
        if len(body) > LIMIT:
            raise ValueError("request too large")
        frame = struct.pack(">I", len(body)) + body
        end = time.monotonic() + timeout
        def ready(fd, write=False):
            remaining = end - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Host IPC deadline")
            r, w, _ = select.select([] if write else [fd], [fd] if write else [], [], remaining)
            if not (r or w):
                raise TimeoutError("Host IPC deadline")
        offset = 0
        while offset < len(frame):
            ready(self.process.stdin.fileno(), True)
            offset += os.write(self.process.stdin.fileno(), frame[offset:])
        def read_exact(count):
            data = b""
            while len(data) < count:
                ready(self.process.stdout.fileno())
                part = os.read(self.process.stdout.fileno(), count - len(data))
                if not part:
                    code = self.process.poll()
                    raise RuntimeError(f"Host exited before reply (returncode={code}); inspect its stderr log")
                data += part
            return data
        length, = struct.unpack(">I", read_exact(4))
        if not 0 < length <= LIMIT:
            raise ValueError("invalid response size")
        response = json.loads(read_exact(length))
        if response.get("id") != request["id"]:
            raise ValueError("response ID mismatch")
        if not response.get("ok"):
            raise RuntimeError(response.get("error", "Host rejected request"))
        return response

    def write(self, path, data, executable=False):
        self.call("write", file={"path": path, "data": base64.b64encode(data).decode(), "executable": executable})

    def read(self, path):
        return base64.b64decode(self.call("read", path=path)["file"]["data"], validate=True)

    def execute(self, argv, timeout=60):
        if self.marker.exists():
            raise RuntimeError("node has an active/recovery marker; refusing candidate launch")
        lease = str(uuid.uuid4())
        self.marker.write_text(json.dumps({"leaseID": lease, "pid": os.getpid(), "state": "acceptance-running"}))
        self.marker.chmod(0o600)
        self.call("exec", leaseID=lease,
                  command={"argv": argv, "cwd": ".", "timeoutSeconds": timeout, "maxLogBytes": 1024 * 1024})
        deadline = time.monotonic() + timeout + 10
        while True:
            result = self.call("executionResult", leaseID=lease).get("result")
            if result is not None:
                break
            if time.monotonic() >= deadline:
                raise TimeoutError("Host execution result deadline")
            time.sleep(0.05)
        outcome = result["outcome"]
        if result.get("leaseID") != lease or outcome["reason"] != "exited" or not outcome["processGroupGone"]:
            raise RuntimeError("execution/cleanup uncertain; recovery marker retained")
        self.marker.unlink()
        if outcome["exitCode"] != 0:
            raise RuntimeError("candidate failed: " + base64.b64decode(result["stderr"]).decode(errors="replace"))
        return base64.b64decode(result["stdout"], validate=True)

    def close(self):
        if self.process.poll() is None:
            try:
                self.call("shutdown", timeout=3)
                self.process.wait(timeout=3)
            except (OSError, RuntimeError, ValueError, TimeoutError, subprocess.TimeoutExpired):
                # Only our exact Host process. An active marker remains in place;
                # terminating Host does not prove candidate/GPU work has drained.
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=3)
        self.process.stdin.close()
        self.process.stdout.close()
        self.log.close()


def run(args):
    if os.getuid() == 0:
        raise RuntimeError("do not run as root")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    report = {"os": platform.platform(), "uid": os.getuid(), "checks": []}
    coordination = Path(f"/private/tmp/metal-sandbox-{os.getuid()}")
    coordination.mkdir(mode=0o700, exist_ok=True)
    st = coordination.lstat()
    if coordination.is_symlink() or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise RuntimeError("unsafe coordination directory")
    lock = os.open(coordination / "daemon.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    hosts = []
    stage = "App Sandbox activation"
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        marker = coordination / "active-lease.json"
        if marker.exists():
            raise RuntimeError("prior recovery marker exists; operator inspection required")
        for role in ("a", "b"):
            identifier = "local.metal-sandbox.acceptance-" + role + "-" + uuid.uuid4().hex
            app = assemble(args.bin_dir.resolve(), output / (identifier + ".app"), identifier)
            host = Host(app, output, marker)
            hosts.append(host)
            host.info = host.call("info")["info"]
            if host.info["bundleID"] != identifier or not host.info["home"].endswith(f"/Library/Containers/{identifier}/Data"):
                raise RuntimeError("container identity mismatch")
        a, b = hosts
        require(a.info['home'] != b.info['home'], "a.info['home'] != b.info['home']")
        report["instances"] = [host.info for host in hosts]
        report["checks"].append({"name": stage, "status": "pass"})
        stage = "Filesystem/inheritance/IPv4 outbound network"
        canary = output / "controller_canary"
        canary.write_bytes(b"controller-only-canary")
        canary.chmod(0o600)
        with canary.open("r+b") as f:
            require(f.read() == b'controller-only-canary', "f.read() == b'controller-only-canary'")
        a.write("self_canary", b"A"); b.write("self_canary", b"B")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0)); listener.listen(8)
            port = listener.getsockname()[1]
            with socket.create_connection(("127.0.0.1", port), timeout=2):
                connection, _ = listener.accept(); connection.close()
            for host, peer in ((a, b), (b, a)):
                own = host.info["workspace"] + "/self_canary"
                foreign = peer.info["workspace"] + "/self_canary"
                probe = host.info["bundle"] + "/Contents/MacOS/sandbox-probe"
                argv = [probe, "--file", own, "--file", foreign, "--file", str(canary), "--port", str(port)]
                # Direct owned child AND owned grandchild via an unchanged system shell.
                for command in (argv, ["/bin/sh", "-c", shlex.join(argv)]):
                    result = json.loads(host.execute(command))
                    for mode in ("read", "write"):
                        require(result['files'][mode + ':' + own]['allowed'], "result['files'][mode + ':' + own]['allowed']")
                        for path in (foreign, str(canary)):
                            denied = result["files"][mode + ":" + path]
                            require(not denied['allowed'] and denied['error'] in (errno.EPERM, errno.EACCES), "not denied['allowed'] and denied['error'] in (errno.EPERM, errno.EACCES)")
                    require(not result['connect']['allowed'] and result['connect']['error'] in (errno.EPERM, errno.EACCES), "not result['connect']['allowed'] and result['connect']['error'] in (errno.EPERM, errno.EACCES)")
                    require(result['extraDescriptors'] == [], result['extraDescriptors'])
        for path in ("../controller_canary", "/etc/passwd", "bad//path"):
            try:
                a.call("read", path=path)
            except RuntimeError:
                pass
            else:
                raise AssertionError("file API accepted path traversal")
        report["checks"].append({"name": stage, "status": "pass"})
        stage = "Native compute/readback and render 1000 frames"
        count = 257
        values = [float(i) for i in range(count)]
        a.write("input.bin", struct.pack("<" + "f" * count * 2, *(values + values)))
        runner = a.info["bundle"] + "/Contents/MacOS/metal-runner"
        a.execute([runner, "--input", "input.bin", "--output", "output.bin", "--metrics", "metrics.json",
                   "--count", str(count), "--iterations", "1000", "--warmup", "3", "--threadgroup", "64"], timeout=120)
        require(a.read('output.bin') == struct.pack('<' + 'f' * count, *(v * 2 for v in values)), "a.read('output.bin') == struct.pack('<' + 'f' * count, *(v * 2 for v in values))")
        metrics = json.loads(a.read("metrics.json"))
        require(len(metrics['gpuSeconds']) == 1000, "1000 GPU timing samples")
        render = json.loads(a.execute([runner, "--render-smoke"], timeout=120))
        require(render['frames'] == 1000 and render['timingSamples'] == 1000 and render['readbackCorrect'], "render['frames'] == 1000 and render['timingSamples'] == 1000 and render['readbackCorrect']")
        require(render['registryID'] == metrics['registryID'], "render['registryID'] == metrics['registryID']")
        report["checks"].append({"name": stage, "status": "pass", "compute": metrics, "render": render})
        stage = "Direct native compilation with controller-pinned toolchain"
        # /usr/bin/clang is Apple's developer-tool shim, which calls xcrun.
        # xcrun explicitly refuses App Sandbox. Resolve the actual installed
        # compiler/SDK in the trusted controller; compilation still runs INSIDE
        # the signed Host with exactly the same minimal sandbox entitlements.
        compiler = subprocess.check_output(["/usr/bin/xcrun", "--find", "clang"], text=True, timeout=10).strip()
        sdk = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-path"], text=True, timeout=10).strip()
        require(Path(compiler).is_absolute() and Path(compiler).is_file(), "compiler must be an installed absolute path")
        require(Path(sdk).is_absolute() and Path(sdk).is_dir(), "SDK must be an installed absolute directory")
        report["toolchain"] = {"compiler": compiler, "sdk": sdk, "resolution": "trusted-controller-only"}
        a.write("fixture_main.c", b'''#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
int main(int argc, char **argv) {
    if (argc == 1) { puts("42"); return 0; }
    int fd = open(argv[1], O_RDONLY);
    if (fd >= 0) { close(fd); puts("allowed"); return 0; }
    if (errno == EPERM || errno == EACCES) { puts("denied"); return 0; }
    return 9;
}
''')
        a.execute([compiler, "-isysroot", sdk, "-mmacosx-version-min=13.0", "fixture_main.c", "-o", "fixture_program"])
        # Agent-produced executables get evaluator-controlled inherit signing.
        # Export/import are byte operations inside Host; no controller follows
        # candidate-created paths or runs the candidate outside App Sandbox.
        candidate = sign_inherited_executable(a.read("fixture_program"), output / "signed_artifacts")
        # Development now executes in place using owned-directory scopes.
        # Separately verify the frozen evaluation publication path: the
        # controller never executes candidate code or strips quarantine.
        identifier = "local.metal-sandbox.acceptance-verifier-" + uuid.uuid4().hex
        app = assemble(args.bin_dir.resolve(), output / (identifier + ".app"), identifier, candidate=candidate)
        verifier = Host(app, output, marker); hosts.append(verifier)
        verifier.info = verifier.call("info")["info"]
        report["instances"].append(verifier.info)
        verifier.write("self_canary", b"verifier")
        executable = verifier.info["bundle"] + "/Contents/MacOS/candidate"
        require(verifier.execute([executable]) == b'42\n', "compiled candidate must return 42")
        require(verifier.execute([executable, verifier.info['workspace'] + '/self_canary']) == b'allowed\n', "compiled candidate must read own canary")
        require(verifier.execute([executable, str(canary)]) == b'denied\n', "compiled candidate must not read controller canary")
        require(verifier.execute([executable, a.info['workspace'] + '/self_canary']) == b'denied\n', "compiled candidate must not read developer container")
        require(verifier.execute([executable, b.info['workspace'] + '/self_canary']) == b'denied\n', "compiled candidate must not read peer container")
        report["candidatePublication"] = "frozen bytes -> fixed inherit signing -> fresh signed Host bundle; no quarantine removal"
        report["checks"].append({"name": stage, "status": "pass"})
        report["result"] = "basic_native_checks_passed"
    except Exception as error:
        report["checks"].append({"name": stage, "status": "failed", "error": str(error)})
        report["result"] = "blocked"
    finally:
        for host in reversed(hosts):
            try:
                host.close()
                if report["result"] != "blocked" and not marker.exists():
                    cleanup_output = output / (host.app.stem + "_cleanup")
                    cleanup_output.mkdir()
                    maintenance = Host(host.app, cleanup_output, marker)
                    try:
                        maintenance.call("purge", timeout=120)
                    finally:
                        maintenance.close()
            except Exception as error:
                report["checks"].append({"name": "cleanup", "status": "failed", "error": str(error)})
                report["result"] = "blocked"
        os.close(lock)
        (output / "acceptance.json").write_text(json.dumps(report, indent=2) + "\n")
        # Keep full timing arrays in the artifact, not thousands of console lines.
        summary = {**report, "checks": [{k: v for k, v in check.items() if k != "compute"} for check in report["checks"]]}
        print(json.dumps(summary, indent=2))
        print("Report:", output / "acceptance.json")
    return 1 if report.get("result") == "blocked" else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, default=Path(".build/debug"))
    parser.add_argument("--output", type=Path, default=Path(".verification") / ("app_sandbox_" + str(time.time_ns())))
    raise SystemExit(run(parser.parse_args()))
