#!/usr/bin/env python3
"""Permanent deletion acceptance. Only deletes freshly owned test instances.

Container inspection is test evidence, never a frontend or manager data path.
No recovery marker is removed or acknowledged by this test.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import stat
import time
from native_management_acceptance import Harness, require


def hashes(directory):
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in directory.rglob("*") if p.is_file()} if directory.exists() else {}


def run(h):
    immutable = None
    try:
        require(not (h.coord / "active-lease.json").exists(), "prior recovery marker; inspect first")
        h.start()
        require(h.call("status")["status"]["permanentDeletionImplemented"], "deletion advertised")
        # Choose lanes explicitly: a static CPU-only `sh -c` is legitimately
        # parallel under the default allowlist and cannot be a serial fixture.
        policy = {"serial": [{"executable": "/bin/sh"}]}
        a, b = h.call("create", count=2, taskPolicy=policy)["instances"]
        aid, bid = a["id"], b["id"]
        require(a["pendingExecutions"] == b["pendingExecutions"] == 0, "new instances report zero pending commands")
        h.write(aid, "fixture_main.c", b'#include <stdio.h>\nint main(void){puts("delete test");}\n')
        h.write(bid, "keep.txt", b"other sandbox")
        h.cli("exec", aid, "--", "clang", "fixture_main.c", "-o", "fixture_program")
        require(h.cli("exec", aid, "--", "./fixture_program").stdout == b"delete test\n", "signed candidate")
        a = h.call("inspect", instanceID=aid)["instance"]
        owned = a["ownedBundleIDs"]
        require(len(owned) == a["revisions"] == 1, "in-place execution retains a complete single-revision journal")
        homes = [Path.home() / "Library/Containers" / identity / "Data" for identity in owned]
        require(all((p / "Library/Application Support/MetalSandbox/workspace/fixture_main.c").is_file() for p in homes), "owned revision holds files")
        exported = h.output / "exported.zip"
        h.cli("export", aid, "--out", str(exported))
        exported_hash = hashlib.sha256(exported.read_bytes()).hexdigest()
        history = hashes(h.coord / "recovery_history")
        executions = hashes(h.state / "executions")
        runtime_audit = hashes(h.state / "runtimes/instances")
        h.reject("delete", instanceID=aid, confirmed=True)
        require(h.cli("delete", aid, success=False).returncode != 0, "CLI requires confirmation")
        handle = h.call("grant", instanceID=bid, operations=["read", "write", "exec"])["handle"]
        h.reject("delete", auth=False, handle=handle, instanceID=aid, confirmed=True)
        h.call("stop", instanceID=aid)
        h.reject("delete", instanceID=aid)
        h.check("delete requires operator, confirmation and an inactive target")

        # After stopping, plant only test-owned entries; purge must not follow
        # links or modify a hard-linked inode outside the owned Data tree.
        canary = h.output / "canary.txt"
        canary.write_text("keep outside")
        for home in homes:
            (home / "outside_link").symlink_to(h.output, target_is_directory=True)
            os.link(canary, home / "hardlink")
            os.mkfifo(home / "fifo", 0o600)
        immutable = homes[0] / "cannot_delete_yet"
        immutable.write_text("intentional deletion failure")
        os.chflags(immutable, stat.UF_IMMUTABLE)
        h.reject("delete", instanceID=aid, confirmed=True)
        failed = h.call("inspect", instanceID=aid)["instance"]
        require(failed["state"] == "delete-failed", "partial deletion remains visible")
        h.reject("restore", instanceID=aid)
        os.chflags(immutable, 0)
        immutable = None
        h.check("partial deletion reports delete-failed, cannot be restored, and supports retry")

        queued_target = h.call("create", count=1, taskPolicy=policy)["instances"][0]
        pending = h.submit(bid, ["/bin/sh", "-c", "printf running > progress.txt; /bin/sleep 15; printf done > progress.txt"])
        for _ in range(100):
            try:
                if h.read(bid, "progress.txt") == b"running":
                    break
            except RuntimeError:
                pass
            time.sleep(0.05)
        else:
            raise AssertionError("other instance did not start its command")
        queued = h.submit(bid, ["/bin/sh", "-c", "printf next > next.txt"])
        own_pending = h.submit(queued_target["id"], ["/bin/sh", "-c", "true"])
        h.reject("delete", instanceID=queued_target["id"], confirmed=True)
        h.call("stop", instanceID=queued_target["id"])
        require(h.wait(own_pending)["state"] == "cancelled", "cancelled waiter retires without waiting for unrelated serial task")
        counts = {r["id"]: r["pendingExecutions"] for r in json.loads(h.cli("list").stdout)["instances"]}
        require(counts == {aid: 0, bid: 2, queued_target["id"]: 0}, "list attributes running/queued and completed cancellation to their own instances")
        require(sum(counts.values()) == h.call("status")["status"]["pendingExecutions"], "per-instance total agrees with global pending count")
        require(h.call("inspect", instanceID=bid)["instance"]["pendingExecutions"] == 2, "inspect reports the same live count")
        h.check("active target remains protected; stopped queued cancellation retires promptly")
        require(h.call("status")["status"]["pendingExecutions"] >= 2, "other work remains queued/running")
        with concurrent.futures.ThreadPoolExecutor() as executor:
            deletion = executor.submit(h.cli, "delete", aid, "--confirm")
            samples = []
            while not deletion.done():
                start = time.monotonic()
                h.call("status")
                h.call("inspect", instanceID=bid)
                samples.append(time.monotonic() - start)
                time.sleep(.02)
            deletion_reply = json.loads(deletion.result().stdout)
        require(samples and max(samples) < 1.0, f'deletion blocks unrelated metadata requests: {samples}')
        h.report['metadataDuringDeletionMaxSeconds'] = max(samples)
        deleted = deletion_reply["instance"]
        require(deleted["state"] == "deleted", "CLI deletion succeeds")
        require(h.read(bid, "progress.txt") == b"running", "deletion must finish without waiting for unrelated command")
        require(h.call("execution", executionID=queued)["execution"]["state"] == "queued", "unrelated queued command retained")
        h.cli("delete", aid, "--confirm")
        require(h.call("inspect", instanceID=bid)["instance"]["physical"]["pid"] == b["physical"]["pid"], "other Host was not restarted")
        require(h.wait(pending)["state"] == "succeeded", "unrelated running command not cancelled")
        require(h.wait(queued)["state"] == "succeeded", "unrelated queued command completes normally")
        require(h.wait(own_pending)["state"] == "cancelled", "stopped target's queued command retires")
        parallel = h.submit(bid, ["/bin/sleep", "1"])
        require(h.call("execution", executionID=parallel)["execution"]["scheduling"] == "parallel", "parallel count fixture")
        require(h.call("inspect", instanceID=bid)["instance"]["pendingExecutions"] == 1, "parallel commands counted too")
        require(h.wait(parallel)["state"] == "succeeded", "parallel command completed")
        require(all(r["pendingExecutions"] == 0 for r in h.call("list")["instances"]), "completed commands do not contribute to counts")
        h.check("per-instance counts cover running, queued, cancelled-but-retiring, parallel and completed commands")
        h.cli("delete", queued_target["id"], "--confirm")
        h.check("CLI deletion and idempotent retry succeed while another instance runs; unrelated commands and Host remain intact")
        for home, identity in zip(homes, owned):
            require(not (home / "Library/Application Support/MetalSandbox").exists(), "all task data removed")
            require(not (home / "hardlink").exists() and not (home / "outside_link").is_symlink(), "links removed")
            require(not (h.state / "runtimes" / identity).exists(), "old executable bundle removed")
            if home.parent.exists():
                require(any(identity in warning for warning in deletion_reply.get("warnings", [])), "OS-protected shell retention is explicit, never silent success")
                require(not any(p.is_file() and not p.is_symlink() for p in home.rglob("*")), "no ordinary task files remain")
        require(not (h.state / "instances" / (aid + ".json")).exists(), "active record removed")
        require(not (h.state / "checkpoints" / (aid + ".zip")).exists(), "checkpoint removed")
        require((h.state / "deleted_instances" / (aid + ".json")).is_file(), "deletion audit retained")
        require(canary.read_text() == "keep outside", "external canary unchanged")
        require(h.read(bid, "keep.txt") == b"other sandbox", "other sandbox unaffected")
        require(hashlib.sha256(exported.read_bytes()).hexdigest() == exported_hash, "independent export retained")
        require(all(hashes(h.state / "executions").get(p) == sha for p, sha in executions.items()), "execution history retained")
        # Stop changes the session state; it must still exist after deletion.
        require(all(Path(p).is_file() for p in runtime_audit), "runtime audit retained")
        require(hashes(h.coord / "recovery_history") == history, "recovery evidence untouched")
        require(aid not in [r["id"] for r in h.call("list")["instances"]], "removed from list")
        h.reject("read", instanceID=aid, path="fixture_main.c")
        h.reject("restore", instanceID=aid)
        h.cli("delete", aid, "--confirm")
        h.check("all owned revisions purged; neighbor, exported artifact and audit preserved; full ID retry is idempotent")

        # Corrupt only owned test records; incomplete ownership must fail closed.
        c = h.call("create", count=1)["instances"][0]
        h.call("stop", instanceID=c["id"])
        h.call("stop", instanceID=bid)
        h.call("shutdown"); h.process.wait(timeout=20)
        originals = {}
        for item in [b, c]:
            path = h.state / "instances" / (item["id"] + ".json")
            record = json.loads(path.read_text()); originals[path] = dict(record)
            record.pop("ownedBundleIDs")
            path.write_text(json.dumps(record))
        h.start()
        require(aid not in [r["id"] for r in h.call("list")["instances"]], "deletion survives restart")
        h.cli("delete", aid, "--confirm")
        for item in [b, c]:
            h.reject("delete", instanceID=item["id"], confirmed=True)
            h.reject("start", instanceID=item["id"])
            require(h.call("inspect", instanceID=item["id"])["instance"]["state"] == "stopped", "ownership refusal preserves record")
        h.check("restart persistence and incomplete ownership fail closed")
        h.call("shutdown"); h.process.wait(timeout=20)
        for path, record in originals.items(): path.write_text(json.dumps(record))
        h.start()
        h.cli("delete", bid, "--confirm"); h.cli("delete", c["id"], "--confirm")
        require(not h.call("list")["instances"], "acceptance leaves no owned logical instances or task data")
        h.report["result"] = "passed"
    except Exception as error:
        h.report["result"] = "failed"; h.report["error"] = repr(error)
        raise
    finally:
        if immutable and immutable.exists():
            os.chflags(immutable, 0)
        if h.process and h.process.poll() is None:
            h.call("shutdown"); h.process.wait(timeout=30)
        h.report["activeLeaseRemains"] = (h.coord / "active-lease.json").exists()
        (h.output / "report.json").write_text(json.dumps(h.report, indent=2) + "\n")
        for log in h.logs:
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if os.getuid() == 0:
        raise SystemExit("do not run as root")
    run(Harness(args.bin_dir, args.output))
