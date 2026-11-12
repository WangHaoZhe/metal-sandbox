import argparse
import getpass
import json
import subprocess
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--cli", type=Path, required=True)
parser.add_argument("--host", required=True)
parser.add_argument("--user", required=True)
parser.add_argument("--port", type=int, default=22)
parser.add_argument("--remote-cli", required=True)
parser.add_argument("--remote-state", required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--password", action="store_true")
args = parser.parse_args()
request = {
    "host": args.host,
    "user": args.user,
    "port": args.port,
    "node": {
        "id": "ssh_acceptance_worker",
        "sshDestination": args.user + "@" + args.host,
        "cliPath": args.remote_cli,
        "stateDirectory": args.remote_state,
    },
}
checks = []


def invoke(operation, body, success=True):
    result = subprocess.run(
        [str(args.cli.resolve()), "cluster-ssh", operation],
        input=json.dumps(body).encode(), capture_output=True, timeout=155,
    )
    secret = body.get("password")
    if secret:
        assert secret.encode() not in result.stdout + result.stderr
    if success:
        assert result.returncode == 0, result.stderr.decode()
        return json.loads(result.stdout)
    assert result.returncode != 0, "request unexpectedly succeeded"
    return result.stderr.decode()


invalid = dict(request, port=0)
assert "invalid SSH" in invoke("scan", invalid, success=False)
checks.append("invalid port rejected")
scan = invoke("scan", request)
assert "SHA256:" in scan["fingerprint"]
checks.append("real SSH host key scan")
request["hostKeys"] = scan["hostKeys"]

if args.password:
    probe = invoke("connect", request)
    configured = probe["node"]
    ssh = ["/usr/bin/ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
           "-o", 'UserKnownHostsFile="' + configured["knownHostsFile"] + '"', "-i", configured["identityFile"],
           "-o", "IdentitiesOnly=yes", "-p", str(args.port), configured["sshDestination"],
           'shasum -a 256 "$HOME/.ssh/authorized_keys"']
    before = subprocess.check_output(ssh, timeout=10)
    secret = getpass.getpass("Remote login password (memory only): ")
    assert secret
    invalid = dict(request, password="deliberately_invalid_ssh_password")
    failure = invoke("connect", invalid, success=False)
    assert "Permission denied" in failure or "SSH connection timed out" in failure, failure
    assert subprocess.check_output(ssh, timeout=10) == before
    checks.append("wrong password cannot install a key; " + ("bounded timeout" if "timed out" in failure else "SSH denial") + "; no secret in CLI output")
    result = invoke("connect", dict(request, password=secret))
    secret = None
    checks.append("password authentication, public key installation, live remote service")
else:
    result = invoke("connect", request)
    checks.append("existing dedicated key authentication, live remote service")

node = result["node"]
assert node["sshPort"] == args.port
assert Path(node["identityFile"]).stat().st_mode & 0o777 == 0o600
assert Path(node["knownHostsFile"]).stat().st_mode & 0o777 == 0o600
checks.append("private key and pinned host key permissions")
repeat = invoke("connect", request)
assert repeat["node"] == node
checks.append("subsequent connection without password")

# 使用同一真实服务器的另一种主机密钥，检查已保存的身份不会被覆盖。
other_key = subprocess.check_output(
    ["/usr/bin/ssh-keyscan", "-T", "5", "-p", str(args.port), "-t", "rsa", args.host],
    stderr=subprocess.DEVNULL,
).decode()
assert other_key.strip()
assert "host key changed" in invoke("connect", dict(request, hostKeys=other_key), success=False)
checks.append("changed pinned host key rejected")
invoke("connect", request)
checks.append("rejected key change preserves successful connection")
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps({"checks": checks, "connection": result}, indent=2) + "\n")
print("PASS:", "; ".join(checks))
