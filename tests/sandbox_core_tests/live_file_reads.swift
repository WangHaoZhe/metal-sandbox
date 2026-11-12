import Foundation
import Darwin
import Security
import SandboxCore
import SandboxRuntime

// Explicit opt-in native regression. Only fixed CPU fixtures run, inside a new
// App Sandbox, with a private test coordinator. No daemon/socket/user instances
// or GPU workloads are touched, so a user's rollout need not be interrupted.
private final class LiveReadJob {
    let cancellation = CancellationToken()
    let group = DispatchGroup()
    private let lock = NSLock()
    private var result: Result<NativeResult, Error>?
    init(_ session: SandboxSession, _ command: NativeCommand) {
        group.enter()
        DispatchQueue.global().async {
            let result = Result { try session.execute(command, cancellation: self.cancellation) }
            self.lock.lock(); self.result = result; self.lock.unlock()
            self.group.leave()
        }
    }
    func finish() throws -> NativeResult {
        guard group.wait(timeout: .now() + 15) == .success else { throw SandboxError("native test execution did not finish") }
        lock.lock(); defer { lock.unlock() }
        return try result!.get()
    }
}

func runShellTaskCounts(bin: URL, output: URL) throws {
    try SafeFiles.secureDirectory(output)
    let scheduler = try ExecutionScheduler(coordinationDirectory: output.appendingPathComponent("coordination"))
    let factory = try AppSandboxFactory(binDirectory: bin, directory: output.appendingPathComponent("runtime"), scheduler: scheduler)
    let logicalID = "sbx-" + UUID().uuidString.lowercased()
    let policy = TaskPolicy(parallel: [.init("/bin/sleep"), .init("/bin/echo")])
    let host = try factory.create(logicalID: logicalID, taskPolicy: policy)
    var purged = false
    defer { try? host.close(); if !purged { _ = try? factory.purge(host.id, logicalID: logicalID) } }
    func require(_ value: Bool, _ message: String) throws { if !value { throw SandboxError(message) } }
    func waitForCounts(_ expected: ExecutionCounts) throws {
        let until = Date().addingTimeInterval(5)
        while scheduler.counts.total != expected {
            guard Date() < until else { throw SandboxError("task counters did not reach \(expected)") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try require(scheduler.counts.byOwner[host.id, default: ExecutionCounts()] == expected, "all parent/tool counts belong to this Host")
    }
    var parallel = NativeCommand(["/bin/bash", "-c", "\"$METAL_SANDBOX_SHELL_HELPER\" 'sleep 1.5' & \"$METAL_SANDBOX_SHELL_HELPER\" 'sleep 1.5' & wait"], timeoutSeconds: 15)
    parallel.agentSession = true
    let first = LiveReadJob(host, parallel)
    try waitForCounts(ExecutionCounts(parallelRunning: 3))
    try require(scheduler.pendingCount == 3, "parent plus two parallel tools must total three")
    let completed = try first.finish()
    try require(completed.outcome.exitCode == 0, "parallel shell commands failed")
    try waitForCounts(ExecutionCounts())
    try require(scheduler.pendingCount == 0, "completed parallel counters leaked")
    var mixed = NativeCommand(["/bin/bash", "-c", "\"$METAL_SANDBOX_SHELL_HELPER\" 'sleep 10' & \"$METAL_SANDBOX_SHELL_HELPER\" 'cd .; sleep 10' & \"$METAL_SANDBOX_SHELL_HELPER\" 'cd .; sleep 10' & wait"], timeoutSeconds: 20)
    mixed.agentSession = true
    let second = LiveReadJob(host, mixed)
    try waitForCounts(ExecutionCounts(parallelRunning: 2, serialRunning: 1, serialWaiting: 1))
    try require(scheduler.pendingCount == 4, "parallel, running serial and queued serial tools must all count")
    second.cancellation.cancel()
    do { _ = try second.finish() } catch is UncertainExecution {
        try require(scheduler.recoveryReason != nil, "uncertain cleanup must stay quarantined")
    }
    try waitForCounts(ExecutionCounts())
    try require(scheduler.pendingCount == 0, "cancelled tool counters leaked")
    try host.close()
    if scheduler.recoveryReason == nil { try scheduler.requireInspection("file-only deletion fixture, no GPU workload") }
    let preserved = scheduler.recoveryReason
    _ = try factory.purge(host.id, logicalID: logicalID); purged = true
    try require(scheduler.recoveryReason == preserved, "file-only cleanup must not clear quarantine")
    try SafeFiles.write(["result": "passed", "parallelParentPlusTools": "3", "mixedParentPlusTools": "4", "afterCancellation": "0", "quarantinePreserved": "true"], to: output.appendingPathComponent("report.json"))
    print("PASS native tool counts: parallel + queued/running serial, completion/cancellation, quarantine-preserving cleanup")
}

func runLiveFileReads(bin: URL, output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SandboxError("use a new native test output directory") }
    try SafeFiles.secureDirectory(output)
    let scheduler = try ExecutionScheduler(coordinationDirectory: output.appendingPathComponent("cpu_only_coordination"))
    let factory = try AppSandboxFactory(binDirectory: bin, directory: output.appendingPathComponent("runtime"), scheduler: scheduler)
    let host = try factory.create()
    let registry = SandboxRegistry(), owner = try registry.register(host)
    let client = registry.client(owner)
    let reader = registry.client(try registry.grant(owner, operations: [.read]))
    var jobs: [LiveReadJob] = []
    var checks: [String] = []
    defer {
        for job in jobs { job.cancellation.cancel(); _ = job.group.wait(timeout: .now() + 15) }
        try? client.close()
        if scheduler.recoveryReason == nil { _ = try? factory.purge(host.id) }
    }
    func require(_ condition: @autoclosure () throws -> Bool, _ detail: String) throws {
        guard try condition() else { throw SandboxError(detail) }
    }
    func denied(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw SandboxError("unsafe or conflicting operation was accepted")
    }
    let container = URL(fileURLWithPath: host.info.home).deletingLastPathComponent()
    try require(FileManager.default.displayName(atPath: container.path) == "MetalSandboxHost",
                "fresh Host must be registered for Finder before returning the session")
    func start(_ script: String, marker: String, timeout: Double = 40) throws -> LiveReadJob {
        let job = LiveReadJob(client, NativeCommand(["/bin/sh", "-c", "printf ready > \(marker); " + script], timeoutSeconds: timeout))
        jobs.append(job)
        let deadline = Date().addingTimeInterval(10)
        while !(try reader.listDirectory(".", after: nil).entries.contains { $0.name == marker }) {
            try require(Date() < deadline, "execution did not reach fixture marker")
            Thread.sleep(forTimeInterval: 0.02)
        }
        return job
    }
    let file = WorkspaceFile(path: "nested/visible.txt", data: Data("visible during execution\n".utf8))
    try client.write(file)
    var bytes = Data(count: 16 * 1024 * 1024)
    try require(bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) } == errSecSuccess,
                "cannot create random transfer fixture")
    try client.write(WorkspaceFile(path: "large.bin", data: bytes))
    _ = try client.execute(NativeCommand(["/bin/sh", "-c", "ln -s nested link; mkfifo fifo; ln large.bin hardlink; mkdir empty; touch .hidden"]))
    let logID = UUID().uuidString.lowercased()
    let logPath = ".claude/rollouts/\(logID)/events.jsonl"
    _ = try client.execute(NativeCommand(["/bin/sh", "-c", "mkdir -p \"$HOME/.claude/rollouts/\(logID)\"; printf 'hello\\n' > \"$HOME/\(logPath)\""]))
    let job = try start("/bin/sleep 30", marker: "ready")
    let began = Date()
    try require(try reader.trajectory(session: nil, after: nil).sessions?.first?.id == logPath, "live trajectory discovery")
    try require(try reader.trajectory(session: logPath, after: nil).page?.data == Data("hello\n".utf8), "live scoped trajectory read")
    let writerOnly = registry.client(try registry.grant(owner, operations: [.write]))
    try denied { _ = try writerOnly.trajectory(session: logPath, after: nil) }
    try denied { _ = try reader.trajectory(session: ".claude/settings.json", after: nil) }
    checks.append("trajectory reads overlap native execution, require read permission and reject non-log HOME files")
    for _ in 0..<5 {
        try require(try reader.listDirectory("nested", after: nil).entries.map(\.path) == [file.path], "nested listing")
        try require(try reader.read(file.path) == file, "live file read")
    }
    try require(Date().timeIntervalSince(began) < 5 && job.group.wait(timeout: .now()) == .timedOut,
                "read waited for execution instead of overlapping it")
    for path in ["..", "/tmp", "link"] { try denied { _ = try reader.listDirectory(path, after: nil) } }
    for path in ["../home/.claude/settings.json", "fifo", "hardlink", "link/visible.txt"] {
        try denied { _ = try reader.read(path) }
    }
    try denied { try client.write(WorkspaceFile(path: "blocked", data: Data())) }
    try denied { _ = try client.export() }
    job.cancellation.cancel()
    let cancelled = try job.finish()
    try require(cancelled.outcome.reason == .cancelled && cancelled.outcome.processGroupGone, "clean live-read cancellation")
    try require(scheduler.recoveryReason == nil, "live-read cancellation quarantined the test node")
    checks.append("live directory/preview reads return before command completion; traversal/links/FIFO, writes and snapshots rejected")
    _ = try client.execute(NativeCommand(["/bin/rm", "hardlink", "fifo", "link"]))

    let finishing = try start("/bin/sleep 0.15; printf completed", marker: "finishing")
    let archive = output.appendingPathComponent("download.zip")
    try reader.download(to: archive, path: "large.bin")
    let downloaded = try WorkspaceArchive.collect(archive)
    try require(downloaded.count == 1 && downloaded[0].data == bytes, "large read lost bytes or mixed exec reply into ZIP frames")
    let completed = try finishing.finish()
    try require(completed.stdout == Data("completed".utf8) && completed.outcome.reason == .exited, "completion reply lost during transfer")
    checks.append("16 MiB random file transfer and overlapping execution completion preserve bytes and replies")

    let transferring = try start("/bin/sleep 30", marker: "transferring")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { transferring.cancellation.cancel() }
    try reader.download(to: archive, path: "large.bin")
    let transferCancelled = try transferring.finish()
    try require(transferCancelled.outcome.reason == .cancelled && transferCancelled.outcome.processGroupGone,
                "cancellation during download did not clean up execution")
    try require(try WorkspaceArchive.collect(archive).first?.data == bytes, "cancellation corrupted file transfer")
    checks.append("one-way cancellation during a large download preserves the transfer and cleans the child")

    let changing = try start("while :; do /usr/bin/touch large.bin; /bin/sleep 0.01; done", marker: "changing")
    do {
        try reader.download(to: archive, path: "large.bin")
        throw SandboxError("changing file was incorrectly accepted as a stable read")
    } catch {
        try require(String(describing: error).contains("file changed during read"), "changing file must return a retryable error")
    }
    changing.cancellation.cancel()
    _ = try changing.finish()
    try require(try WorkspaceArchive.collect(archive).first?.data == bytes, "failed live read replaced the previous download")
    checks.append("changing-file reads fail explicitly without replacing a prior complete download")

    let timed = try start("/bin/sleep 30", marker: "timed", timeout: 0.5)
    try require(try reader.read(file.path) == file, "read during timed execution")
    let expired = try timed.finish()
    try require(expired.outcome.reason == .timedOut && expired.outcome.processGroupGone && scheduler.recoveryReason == nil,
                "clean timeout after reads must not quarantine")
    let after = try client.execute(NativeCommand(["/bin/echo", "after_reads"]))
    try require(after.stdout == Data("after_reads\n".utf8), "subsequent execution unavailable")
    checks.append("timeout cleanup and subsequent execution remain usable")
    try client.close()
    try denied { _ = try reader.read(file.path) }
    try SafeFiles.write(["checks": checks, "result": ["passed"], "scope": ["CPU-only native Host and registry; no running daemon modified"]],
                        to: output.appendingPathComponent("report.json"))
    print("PASS: \(checks.count) native live-file-read groups")
}
