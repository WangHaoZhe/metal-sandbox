#!/usr/bin/env python3
"""Native manager/CLI acceptance using owned, trusted fixtures only.

Never runs candidate binaries on the controller. Exceptional recovery is tested
only for the exact known /bin/sleep (CPU-only) workload after verifying its PID
is gone. Unknown failures keep the lease marker and require operator inspection.
"""
import argparse
import base64
import concurrent.futures
import errno
import json
import os
import plistlib
from pathlib import Path
import signal
import socket
import struct
import subprocess
import time
import uuid
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from release_metadata import release_version, bundle_build


def require(value, message):
    if not value:
        raise AssertionError(message)


class Harness:
    def __init__(self, binary, output):
        self.binary = binary.resolve()
        self.output = output.resolve()
        self.output.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.state = self.output / "state"
        self.coord = Path(os.environ.get("METAL_SANDBOX_COORDINATION_DIR", f"/private/tmp/metal-sandbox-{os.getuid()}"))
        self.process = None
        self.logs = []
        self.report = {"checks": [], "result": "running"}

    def start(self, *extra_args):
        log = (self.output / f"manager_{len(self.logs)}.log").open("wb")
        self.logs.append(log)
        self.process = subprocess.Popen([str(self.binary / "metal-sandboxd"), "--allow-trusted-code",
                                         "--bin-dir", str(self.binary), "--state-dir", str(self.state), *extra_args],
                                        stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        for _ in range(200):
            if self.process.poll() is not None:
                raise RuntimeError("manager exited during startup; inspect its log")
            try:
                self.token = (self.state / "operator_token").read_text()
                status = self.call("status")["status"]
                require(status.get("serviceVersion") == release_version(), "native service version")
                require(status.get("protocolVersion") == 1, "native protocol version")
                self.report["serviceVersion"] = status["serviceVersion"]
                self.report["host"] = status["host"]
                return status
            except (OSError, RuntimeError, ValueError):
                time.sleep(0.05)
        raise TimeoutError("manager startup")

    def call(self, operation, *, auth=True, **fields):
        request = {"requestID": str(uuid.uuid4()), "operation": operation, **fields}
        if auth:
            request["operatorToken"] = self.token
        data = json.dumps(request).encode()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(120)
            connection.connect(str(self.coord / "native.sock"))
            connection.sendall(struct.pack(">I", len(data)) + data)
            def receive(count):
                result = b""
                while len(result) < count:
                    part = connection.recv(count - len(result))
                    if not part:
                        raise RuntimeError("manager disconnected")
                    result += part
                return result
            count, = struct.unpack(">I", receive(4))
            require(0 < count <= 16 * 1024 * 1024, "bounded manager reply")
            reply = json.loads(receive(count))
        require(reply["requestID"] == request["requestID"], "request/reply identity")
        if not reply["ok"]:
            raise RuntimeError(reply.get("error", "request failed"))
        return reply

    def reject(self, operation, **fields):
        try:
            self.call(operation, **fields)
        except RuntimeError:
            return
        raise AssertionError("unexpectedly accepted " + operation)

    def cli(self, *args, input=None, success=True):
        result = subprocess.run([str(self.binary / "sandboxctl"), "--state-dir", str(self.state), "sandbox", *args],
                                input=input, capture_output=True, timeout=180)
        if success and result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace"))
        return result

    def submit(self, instance, argv, timeout=30):
        return self.call("exec", instanceID=instance, command={"argv": argv, "cwd": ".", "timeoutSeconds": timeout,
                         "maxLogBytes": 1024 * 1024})["execution"]["id"]

    def wait(self, execution, timeout=150):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            record = self.call("execution", executionID=execution)["execution"]
            if record["state"] in ("succeeded", "failed", "cancelled", "interrupted"):
                return record
            time.sleep(0.05)
        raise TimeoutError("execution did not finish")

    def execute(self, instance, argv, timeout=30):
        record = self.wait(self.submit(instance, argv, timeout))
        require(record["state"] == "succeeded", str(record))
        return base64.b64decode(record["result"]["stdout"])

    def write(self, instance, path, data):
        self.call("write", instanceID=instance, file={"path": path, "data": base64.b64encode(data).decode(), "executable": False})

    def read(self, instance, path):
        return base64.b64decode(self.call("read", instanceID=instance, path=path)["file"]["data"])

    def check(self, label):
        self.report["checks"].append({"name": label, "status": "pass"})
        print("PASS", label, flush=True)

    def stop_all(self):
        for record in self.call("list")["instances"]:
            if record["state"] in ("active", "publishing"):
                self.call("stop", instanceID=record["id"])

    def delete_owned(self):
        """Only this Harness's dedicated state; do not leave test workspaces."""
        self.stop_all()
        replies = []
        for record in self.call("list")["instances"]:
            replies.append(self.call("delete", instanceID=record["id"], confirmed=True))
        (self.output / "owned_cleanup.json").write_text(json.dumps(replies, indent=2) + "\n")

    def run(self):
        try:
            require(not (self.coord / "active-lease.json").exists(), "prior recovery marker; inspect before running acceptance")
            self.start()
            self.reject("status", auth=False)
            self.reject("create", auth=False, count=1)
            self.reject("unknown_operation")
            records = json.loads(self.cli("create", "--count", "4", "--name", "实验", "--no_network").stdout)["instances"]
            require([r.get("name") for r in records] == [f"实验 ({i})" for i in range(1, 5)], "replica names")
            ids = [r["id"] for r in records]
            require(len(ids) == len(set(ids)) == 4, "four distinct logical sandboxes")
            require(len({r["physical"]["home"] for r in records}) == 4, "four OS containers")
            for record in records:
                info = plistlib.loads((Path(record["physical"]["bundle"]) / "Contents/Info.plist").read_bytes())
                require(info["MetalSandboxVersion"] == release_version(), "Host release identity")
                require(info["CFBundleShortVersionString"] == release_version().split("-")[0], "Apple numeric app version")
                require(info["CFBundleVersion"] == bundle_build(), "Host build identity")
                require(info["CFBundleName"] == info["CFBundleDisplayName"] == "MetalSandboxHost-" + record["id"], "Host display name uses the logical ID")
            self.check("authenticated native manager and CLI create exactly four isolated instances")

            a, b, c, d = ids
            name = "我的实验 $(not-a-command); '引号'"
            renamed = json.loads(self.cli("rename", a, name).stdout)["instance"]
            require(renamed["name"] == name and renamed["physical"] == records[0]["physical"], "rename changes only display metadata")
            self.reject("rename", auth=False, instanceID=a, name="unauthorized")
            self.reject("rename", instanceID=a, name="two\nlines")
            cleared = json.loads(self.cli("rename", d, "").stdout)["instance"]
            require(cleared.get("name") is None, "empty name clears display metadata")
            self.check("optional names, replica suffixes, literal rename, authorization and unchanged process identity")
            self.write(a, "same.txt", b"A"); self.write(b, "same.txt", b"B")
            require(self.read(a, "same.txt") == b"A" and self.read(b, "same.txt") == b"B", "persistent isolated workspaces")
            self.reject("read", instanceID=a, path="../operator_token")
            own = records[0]["physical"]["workspace"] + "/same.txt"
            foreign = records[1]["physical"]["workspace"] + "/same.txt"
            probe = records[0]["physical"]["bundle"] + "/Contents/MacOS/sandbox-probe"
            observed = json.loads(self.execute(a, [probe, "--file", own, "--file", foreign, "--file", str(self.state / "operator_token")]))
            for mode in ("read", "write"):
                require(observed["files"][mode + ":" + own]["allowed"], "own canary")
                for path in (foreign, str(self.state / "operator_token")):
                    access = observed["files"][mode + ":" + path]
                    require(not access["allowed"] and access["error"] in (errno.EPERM, errno.EACCES), "foreign/controller denial")
            require(observed["extraDescriptors"] == [], "no inherited control descriptors")
            self.check("real filesystem boundary, scoped file channel and no inherited control FDs")

            with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as v6, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                v6.bind(("::1", 0)); v6.listen(2)
                udp.bind(("127.0.0.1", 0))
                with socket.create_connection(("::1", v6.getsockname()[1]), timeout=2):
                    accepted, _ = v6.accept(); accepted.close()
                networks = json.loads(self.execute(a, [probe, "--unix", str(self.coord / "native.sock"),
                    "--ipv6-port", str(v6.getsockname()[1]), "--udp-port", str(udp.getsockname()[1])]))["connections"]
                require(set(networks) == {"unix", "ipv6", "udp"}, "all network probes ran")
                require(all(not value["allowed"] and value["error"] in (errno.EPERM, errno.EACCES) for value in networks.values()), "network and management socket deny")
            self.check("candidate cannot connect management Unix socket, IPv6 TCP or IPv4 UDP")

            console = self.cli("enter", a, input=b"echo entered > console.txt\ncat console.txt\nexit\n")
            require(console.stdout == b"entered\n", "managed console routes each command")
            require(self.read(a, "console.txt") == b"entered\n", "leaving console preserves workspace")
            require(self.cli("exec", a, "--", "echo", "direct").stdout == b"direct\n", "direct CLI exec")
            self.check("enter/exit and direct exec use a persistent selected sandbox")

            setup_source = self.output / "setup.sh"
            setup_source.write_text("#!/bin/sh\nset -eu\ntest -s instruction.md\nmkdir -p input output\ncp instruction.md input/instruction.md\nprintf 'workspace ready\\n' > output/setup_result.txt\ncat output/setup_result.txt\n")
            prompt_source = self.output / "instruction.md"
            prompt_source.write_text("A fixture task for the preparation API.\n")
            self.cli("write", a, "setup.sh", "--from", str(setup_source))
            missing_prompt = self.cli("exec", a, "--", "/bin/sh", "./setup.sh", success=False)
            require(missing_prompt.returncode != 0, "setup stops on missing prompt")
            require(not self.call("status")["status"].get("recoveryReason"), "normal setup failure does not quarantine")
            self.reject("read", instanceID=a, path="output/setup_result.txt")
            self.cli("write", a, "instruction.md", "--from", str(prompt_source))
            for _ in range(2):
                setup = self.cli("exec", a, "--timeout", "120", "--", "/bin/sh", "./setup.sh")
                require(setup.stdout == b"workspace ready\n", "setup script runs and can be repeated")
            require(self.cli("read", a, "output/setup_result.txt").stdout == b"workspace ready\n", "setup files persist")
            require(self.cli("exec", a, "--", "/bin/cat", "input/instruction.md").stdout == prompt_source.read_bytes(), "next command reads unchanged prompt")
            self.reject("read", instanceID=b, path="input/instruction.md")
            self.check("generic setup and prompt use existing write/exec with failure propagation and persistent files")

            original_home = self.call("inspect", instanceID=a)["instance"]["physical"]["home"]
            for value in (42, 43):
                self.write(a, "fixture_main.c", f'#include <stdio.h>\nint main(void) {{ puts("{value}"); return 0; }}\n'.encode())
                self.cli("exec", a, "--", "clang", "fixture_main.c", "-o", "fixture_program")
                require(self.cli("exec", a, "--", "./fixture_program").stdout == f"{value}\n".encode(), "execute newly published revision")
            revised = self.call("inspect", instanceID=a)["instance"]
            require(revised["revisions"] == 1 and revised["physical"]["home"] == original_home, "in-place development, stable logical and physical identity")
            require(self.read(a, "console.txt") == b"entered\n", "workspace survives executable publication")
            self.check("native clang and repeated in-place execution without replacing the development container")

            ro = self.call("grant", instanceID=b, operations=["read"])["handle"]
            self.call("read", auth=False, handle=ro, instanceID=b, path="same.txt")
            self.reject("exec", auth=False, handle=ro, instanceID=b, command={"argv": ["/bin/echo", "bad"], "cwd": ".", "timeoutSeconds": 30, "maxLogBytes": 1024})
            self.reject("read", auth=False, handle=ro, instanceID=a, path="same.txt")
            self.reject("recover", auth=False, handle=ro, confirmed=True, note="forged")
            self.check("operation-scoped capabilities reject cross-instance execution and operator recovery")

            # finishedAt includes post-execution snapshot work, which need not
            # retain the serial slot. Measure actual child execution instead.
            from task_scheduling_acceptance import STAMP, interval
            for instance in ids:
                self.write(instance, "serial_stamp.c", STAMP)
                self.execute(instance, ["clang", "serial_stamp.c", "-o", "serial_stamp"])
            jobs = [self.submit(instance, ["./serial_stamp", "fifo", ".15"]) for instance in ids]
            results = [self.wait(job) for job in jobs]
            windows = [interval(result) for result in results]
            for current, following in zip(windows, windows[1:]):
                require(current[2] <= following[1], "FIFO child execution windows must not overlap")
            require(all(r["state"] == "succeeded" for r in results), "all queued commands completed")
            self.report["serialExecutions"] = results
            self.check("non-allowlisted tasks from four instances share one FIFO serial slot")

            gpu = revised["physical"]["bundle"] + "/Contents/MacOS/metal-runner"
            render = json.loads(self.execute(a, [gpu, "--render-smoke"], 120))
            require(render["frames"] == 1000 and render["readbackCorrect"], "native render smoke")
            self.report["render"] = render
            self.check("1000 native Metal render frames through the public manager")

            self.call("stop", instanceID=b)
            self.reject("read", auth=False, handle=ro, instanceID=b, path="same.txt")
            restored = self.call("restore", instanceID=b)["instance"]
            require(restored["id"] != b and self.read(restored["id"], "same.txt") == b"B", "restore uses a new identity with saved bytes")
            checkpoint = self.state / "checkpoints" / (b + ".zip")
            saved = checkpoint.read_bytes()
            tampered = bytearray(saved); tampered[-1] ^= 1
            checkpoint.write_bytes(tampered)
            self.reject("restore", instanceID=b)
            checkpoint.write_bytes(saved)
            self.check("stop revokes handles; restore uses an integrity-checked checkpoint and fresh identity")

            self.reject("start", auth=False, handle=ro, instanceID=b)
            restarted = json.loads(self.cli("start", b).stdout)["instance"]
            require(restarted["id"] == b and restarted["createdAt"] == records[1]["createdAt"], "start preserves logical identity and creation date")
            for field in ("home", "workspace", "bundle", "bundleID"):
                require(restarted["physical"][field] == records[1]["physical"][field], "start preserves " + field)
            require(restarted["physical"]["pid"] != records[1]["physical"]["pid"], "fresh Host process")
            self.reject("start", instanceID=b)
            self.reject("read", auth=False, handle=ro, instanceID=b, path="same.txt")
            require(self.read(b, "same.txt") == b"B", "same workspace reopened")
            self.execute(b, ["/bin/sh", "-c", 'printf private_home > "$HOME/start_marker"; pwd > before_start.txt'])
            self.call("stop", instanceID=b)
            # Starting the original does not depend on a valid snapshot.
            checkpoint.write_text("invalid checkpoint")
            restarted = self.call("start", instanceID=b)["instance"]
            require(self.execute(b, ["/bin/sh", "-c", 'cat "$HOME/start_marker"; test "$(pwd)" = "$(cat before_start.txt)"']) == b"private_home", "private HOME and absolute workspace preserved")
            require(len([r for r in self.call("list")["instances"] if r["id"] == b]) == 1, "start does not duplicate history in list")
            self.check("start preserves original ID, directories and private HOME; rotates handles and does not depend on snapshot")

            episode_dir = self.output / "managed_episode"
            episode_process = subprocess.run([str(self.binary / "evaluation-runner"), "--managed-smoke", "--state-dir", str(self.state),
                                              "--output", str(episode_dir)], capture_output=True, timeout=180)
            require(episode_process.returncode == 0, episode_process.stderr.decode(errors="replace"))
            episode = json.loads((episode_dir / "managed_episode.json").read_text())
            require(episode["state"] == "succeeded" and episode["turns"] == 4 and episode["verification"]["correctness"], "managed Agent/Verifier episode")
            self.report["managedEpisode"] = episode
            self.check("multi-turn Agent/Verifier, frozen artifacts and native Metal over scoped public RPC")

            blocker = self.submit(c, ["/bin/sh", "-c", "/bin/sleep 0.5"])
            queued = self.submit(d, ["/bin/sh", "-c", "/bin/echo must-not-run"])
            self.call("cancel", executionID=queued)
            require(self.wait(blocker)["state"] == "succeeded" and self.wait(queued)["state"] == "cancelled", "queued cancellation")
            require(not self.call("status")["status"].get("recoveryReason"), "no quarantine when nothing launched")
            self.check("queued cancellation does not launch or falsely quarantine the node")

            self.report['cleanedCancellations'] = []
            for argv, signal_or_exit in [(['/bin/sleep', '200'], 'term'),
                    (['/bin/sh', '-c', 'trap "echo cancelled_cleanup; exit 0" TERM; while :; do sleep .05; done'], 'zero'),
                    (['/bin/sh', '-c', 'trap "" TERM; sleep 200 & wait'], 'kill')]:
                host = self.call('inspect', instanceID=c)['instance']['physical']['pid']
                active = self.submit(c, argv)
                time.sleep(0.4)
                peer = self.submit(d, ['/bin/sh', '-c', 'echo peer_continues'])
                self.call('cancel', executionID=active)
                cancelled = self.wait(active)
                outcome = cancelled['result']['outcome']
                require(cancelled['state'] == 'cancelled' and outcome['reason'] == 'cancelled', 'cancellation is not failure or success')
                require(outcome['processID'] > 0 and outcome['processGroupGone'], 'actual child/group cleaned')
                if signal_or_exit == 'zero':
                    require(outcome.get('exitCode') == 0 and b'cancelled_cleanup' in base64.b64decode(cancelled['result']['stdout']), 'zero-exit handler still cancelled; logs retained')
                if signal_or_exit == 'kill': require(outcome.get('terminationSignal') == 9, 'TERM-resistant cancellation uses KILL')
                require(not self.call('status')['status'].get('recoveryReason'), 'cleaned cancellation does not quarantine')
                require(self.wait(peer)['state'] == 'succeeded', 'other sandbox and queued serial work continue')
                require(self.execute(c, ['/bin/echo', 'same_host_continues']) == b'same_host_continues\n', 'cancelled Host remains usable')
                require(self.call('inspect', instanceID=c)['instance']['physical']['pid'] == host, 'no Host replacement')
                self.report['cleanedCancellations'].append(cancelled)
            self.check('cleaned TERM/KILL cancellations retain cancelled state and logs; same Host and peer work continue without recovery')

            fresh = self.call("create", count=1)["instances"][0]["id"]
            timed = self.wait(self.submit(fresh, ["/bin/sleep", "5"], 0.2))
            require(timed["state"] == "failed" and timed["result"]["outcome"]["reason"] == "timedOut", "native timeout remains failed")
            require(timed["result"]["outcome"]["processGroupGone"], "timed-out process group cleaned")
            require(not self.call("status")["status"].get("recoveryReason"), "cleaned timeout does not quarantine")
            require(self.execute(fresh, ["/bin/echo", "after_timeout"]) == b"after_timeout\n", "same Host accepts next command")
            self.check("runtime timeout stays failed, releases lease and permits the next command without recovery")

            self.call("shutdown"); self.process.wait(timeout=20)
            require(self.process.returncode == 0, "clean native service shutdown")
            status = self.start()
            require(status["activeInstances"] == 0 and not status.get("recoveryReason"), "idle restart has no replay")
            require(self.call("inspect", instanceID=a)["instance"].get("name") == name, "name persists across manager restart")
            renamed_stopped = self.call("rename", instanceID=b, name="停止实例")["instance"]
            require(renamed_stopped["state"] == "stopped" and renamed_stopped["name"] == "停止实例", "rename does not start a stopped instance")
            again = self.call("start", instanceID=a)["instance"]["id"]
            require(again == a, "same ID after daemon restart")
            require(self.read(again, "console.txt") == b"entered\n", "checkpoint survives service restart")
            self.check("clean shutdown/restart retains history and checkpoints without replaying instances")

            # Crash only our Popen-owned manager while its exact known CPU-only
            # sleep runs; retain provenance and verify both real processes exit.
            victim = self.call("create", count=1)["instances"][0]
            host_pid = victim["physical"]["pid"]
            interrupted = self.submit(victim["id"], ["/bin/sleep", "30"])
            time.sleep(0.4)
            processes = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,comm="], text=True)
            children = []
            for line in processes.splitlines():
                fields = line.strip().split(None, 2)
                if len(fields) == 3 and int(fields[1]) == host_pid:
                    require(fields[2] == "/bin/sleep", "only the expected direct CPU child may run")
                    children.append(int(fields[0]))
            require(len(children) == 1, "observed exact sleep before manager crash")
            manager_pid = self.process.pid
            self.process.kill(); self.process.wait(timeout=5)
            for pid in [host_pid, *children]:
                gone = False
                for _ in range(100):
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        gone = True; break
                    time.sleep(0.05)
                require(gone, "manager EOF must cancel/reap owned Host/child; leave marker if uncertain")
            status = self.start()
            require(status.get("recoveryReason"), "crash lease preserved")
            require(self.call("execution", executionID=interrupted)["execution"]["state"] == "interrupted", "no replay after crash")
            self.reject("create", count=1)
            self.reject("start", instanceID=victim["id"])
            evidence = {"managerPID": manager_pid, "hostPID": host_pid, "childPIDs": children, "allGone": True, "gpuSubmitted": False}
            (self.output / "manager_crash_recovery.json").write_text(json.dumps(evidence, indent=2))
            self.call("recover", confirmed=True, note="Acceptance operator: killed only owned manager during exact /bin/sleep; recorded Host and sleep PIDs are gone; no GPU work submitted.")
            self.check("manager crash closes private pipe, reaps known child, revokes live instances and retains recovery gate")
            require(self.call("start", instanceID=victim["id"])["instance"]["id"] == victim["id"], "verified interrupted instance reopens after explicit recovery")
            self.delete_owned()
            self.report["result"] = "passed"
        except Exception as error:
            self.report["result"] = "failed"; self.report["error"] = repr(error)
            raise
        finally:
            if self.process and self.process.poll() is None:
                try:
                    self.call("shutdown"); self.process.wait(timeout=20)
                except Exception:
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        self.process.kill(); self.process.wait()
            self.report["activeLeaseRemains"] = (self.coord / "active-lease.json").exists()
            (self.output / "report.json").write_text(json.dumps(self.report, indent=2) + "\n")
            for log in self.logs:
                log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if os.getuid() == 0:
        raise SystemExit("do not run as root")
    Harness(args.bin_dir, args.output).run()
