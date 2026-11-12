import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import threading
import time
from urllib.request import urlopen
import uuid


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def closed_port(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
            return False
    except OSError:
        return True


def run(bin_dir, output, ssh):
    output.mkdir(parents=True, mode=0o700)
    (output / "temporary").mkdir()
    (output / "bin").symlink_to(bin_dir, target_is_directory=True)
    environment = dict(os.environ, METAL_SANDBOX_COORDINATION_DIR=str(output / "c"), TMPDIR=str(output / "temporary"))
    cli = [str(bin_dir / "sandboxctl"), "--state-dir", str(output / "state"), "sandbox"]
    checks, instances = [], []
    served = output / "served"
    served.mkdir()
    expected = os.urandom(65536)
    (served / "payload").write_bytes(expected)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=served))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_port
    service = None
    sshd = None

    def command(*args, succeeds=True):
        result = subprocess.run([*cli, *args], env=environment, capture_output=True, text=True, timeout=120)
        if succeeds:
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)
        assert result.returncode != 0, "request unexpectedly succeeded"
        return result.stderr

    try:
        subprocess.run([str(bin_dir / "sandbox-selftest"), "--loopback-forwards", str(port)], env=environment, check=True, timeout=20)
        checks.append("real TCP lease validation, renewal, expiration and cleanup")
        with (output / "service.log").open("w") as log:
            service = subprocess.Popen([str(bin_dir / "metal-sandboxd"), "--allow-trusted-code", "--bin-dir", str(bin_dir), "--state-dir", str(output / "state")], env=environment, stdout=log, stderr=subprocess.STDOUT)
        for _ in range(100):
            assert service.poll() is None, "test service exited"
            probe = subprocess.run([*cli, "status"], env=environment, capture_output=True)
            if probe.returncode == 0:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("test service did not start")
        assert command("status")["status"]["loopbackForwardingImplemented"]
        instance = command("create", "--count", "1")["instances"][0]["id"]
        instances.append(instance)
        lease = str(uuid.uuid4())
        opened = command("forward", instance, "--port", str(port), "--lease", lease)["portForward"]
        assert opened["port"] == port and opened["id"] == lease
        assert command("inspect", instance)["instance"]["loopbackForwardIDs"] == [lease]
        command("forward", instance, "--port", str(port), "--lease", lease)
        command("forward", instance, "--port", "0", "--lease", str(uuid.uuid4()), succeeds=False)
        command("forward", instance, "--port", str(port), "--lease", str(uuid.uuid4()), succeeds=False)
        assert command("inspect", instance)["instance"]["loopbackForwardIDs"] == [lease]
        result = subprocess.run([*cli, "exec", instance, "--", "/usr/bin/curl", "--fail", "--silent", "--noproxy", "*", f"http://127.0.0.1:{port}/payload"], env=environment, capture_output=True, timeout=30)
        assert result.returncode == 0 and result.stdout == expected, result.stderr
        handle = output / "read_handle.json"
        subprocess.run([*cli, "grant", instance, "--operations", "read", "--out", str(handle)], env=environment, check=True, capture_output=True)
        command("--handle", str(handle), "forward", instance, "--port", str(port), "--lease", str(uuid.uuid4()), succeeds=False)
        command("stop", instance)
        command("start", instance)
        assert command("inspect", instance)["instance"]["loopbackForwardIDs"] == [lease]
        command("forward-status", instance, lease)
        command("stop", instance)
        command("delete", instance, "--confirm")
        instances.remove(instance)
        command("forward-status", instance, lease, succeeds=False)
        command("forward-close", instance, lease)
        checks.append("real App Sandbox access, scoped denial, stable dependencies across restart, deletion cleanup")

        if ssh:
            ssh_port = free_port()
            for name in ("host_key", "client_key"):
                subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(output / name)], check=True)
            config = output / "sshd_config"
            user = subprocess.check_output(["id", "-un"], text=True).strip()
            config.write_text(
                f"Port {ssh_port}\nListenAddress 127.0.0.1\nHostKey {output / 'host_key'}\n"
                f"PidFile {output / 'sshd.pid'}\nAuthorizedKeysFile {output / 'client_key.pub'}\n"
                f"AllowUsers {user}\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n"
                "PermitRootLogin no\nAllowTcpForwarding remote\nGatewayPorts no\nStrictModes yes\nLogLevel VERBOSE\n"
            )
            with (output / "sshd.log").open("w") as log:
                sshd = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stdout=log, stderr=subprocess.STDOUT)
            for _ in range(100):
                assert sshd.poll() is None, "local user-mode sshd could not start; inspect sshd.log"
                if not closed_port(ssh_port):
                    break
                time.sleep(0.1)
            known = output / "known_hosts"
            scanned = subprocess.run(["ssh-keyscan", "-T", "5", "-p", str(ssh_port), "127.0.0.1"], capture_output=True, check=True)
            known.write_bytes(scanned.stdout)
            known.chmod(0o600)
            relay = Path(__file__).with_name("loopback_relay.sh")
            node = {
                "id": "local_ssh", "sshDestination": user + "@127.0.0.1", "sshPort": ssh_port,
                "cliPath": str(relay.resolve()), "stateDirectory": str(output / "state"),
                "identityFile": str(output / "client_key"), "knownHostsFile": str(known),
            }
            node_file = output / "node.json"
            node_file.write_text(json.dumps(node))
            collision = subprocess.run([str(bin_dir / "sandbox-selftest"), "--ssh-forward", str(node_file), str(port), str(port)], env=environment, capture_output=True, text=True, timeout=20)
            assert collision.returncode != 0, "remote bind collision was accepted"
            for abrupt in (False, True):
                listen = free_port()
                forwarding = subprocess.Popen([str(bin_dir / "sandbox-selftest"), "--ssh-forward", str(node_file), str(port), str(listen)], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    with selectors.DefaultSelector() as selector:
                        selector.register(forwarding.stdout, selectors.EVENT_READ)
                        assert selector.select(20), "SSH forwarding readiness timed out"
                    line = forwarding.stdout.readline()
                    assert line == b"READY\n", (line, forwarding.stderr.read())
                    with urlopen(f"http://127.0.0.1:{listen}/payload", timeout=5) as response:
                        assert response.read() == expected
                    if abrupt:
                        forwarding.kill()
                    else:
                        forwarding.stdin.close()
                    forwarding.wait(timeout=10)
                    for _ in range(100):
                        if closed_port(listen):
                            break
                        time.sleep(0.1)
                    assert closed_port(listen), "forwarding port survived its owner"
                finally:
                    if forwarding.poll() is None:
                        forwarding.kill()
                        forwarding.wait(timeout=10)
                    if not forwarding.stdin.closed:
                        forwarding.stdin.close()
            checks.append("real local OpenSSH, authenticated reverse forwarding, payload equality, bind collision, graceful and SIGKILL cleanup")
        (output / "report.json").write_text(json.dumps({"checks": checks}, indent=2))
        print("PASS:", "; ".join(checks))
    finally:
        if sshd is not None and sshd.poll() is None:
            sshd.terminate()
            sshd.wait(timeout=10)
        for instance in instances:
            command("stop", instance)
            command("delete", instance, "--confirm")
        if service is not None and service.poll() is None:
            command("shutdown")
            service.wait(timeout=30)
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ssh", action="store_true")
    options = parser.parse_args()
    run(options.bin_dir.resolve(), options.output.resolve(), options.ssh)
