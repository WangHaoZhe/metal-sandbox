import Foundation
import SandboxCore
import SandboxRuntime

extension RuntimeTests {
    func revealValidation() throws {
        let workspace = try workspace()
        try workspace.write(WorkspaceFile(path: "nested/file.txt", data: Data("ok".utf8)))
        expectNoThrow(try workspace.validateFileOrDirectory("."))
        expectNoThrow(try workspace.validateFileOrDirectory("nested"))
        expectNoThrow(try workspace.validateFileOrDirectory("nested/file.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("work/link").path, withDestinationPath: "nested")
        for path in ["..", "/tmp", "missing", "link", "link/file.txt"] { expectThrows(try workspace.validateFileOrDirectory(path)) }
        let command = NativeCommand(["/bin/echo", "argument-not-for-list"])
        let brief = NativeExecutionBrief(NativeExecutionRecord(id: UUID().uuidString, instanceID: "test", command: command))
        let json = String(decoding: try JSON.data(brief), as: UTF8.self)
        expectFalse(json.contains("argument-not-for-list"))
        expectFalse(json.contains("stdout"))
    }
}

func runFileOnlyHost(bin: URL, output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SandboxError("use fresh test output") }
    try SafeFiles.secureDirectory(output)
    let scheduler = try ExecutionScheduler(coordinationDirectory: output.appendingPathComponent("coordination"))
    let factory = try AppSandboxFactory(binDirectory: bin, directory: output.appendingPathComponent("runtime"), scheduler: scheduler)
    let host = try factory.create()
    let previous = host.info!
    try host.write(WorkspaceFile(path: "file.txt", data: Data("original".utf8)))
    try host.close()
    let logical = "sbx-" + UUID().uuidString.lowercased()
    let files = try factory.start(previous, logicalID: logical, networkClient: false, taskPolicy: TaskPolicy(), fileOnly: true)
    defer { try? files.close(); _ = try? factory.purge(files.id, logicalID: logical) }
    guard files.info.fileOnly == true else { throw SandboxError("not file-only mode") }
    try files.write(WorkspaceFile(path: "nested/new.txt", data: Data("edited".utf8)))
    guard try files.read("nested/new.txt").data == Data("edited".utf8) else { throw SandboxError("file-only read/write") }
    var rejected = false
    do { _ = try files.execute(NativeCommand(["/bin/touch", "must_not_run"])) } catch { rejected = true }
    guard rejected, scheduler.pendingCount == 0, scheduler.recoveryReason == nil else { throw SandboxError("file-only host admitted execution or changed scheduler") }
    guard try files.workspaceLocation("nested") == previous.workspace + "/nested" else { throw SandboxError("workspace location") }
    try scheduler.requireInspection("file-maintenance fixture; no GPU workload")
    let reason = scheduler.recoveryReason
    try files.close()
    _ = try factory.purge(files.id, logicalID: logical)
    guard scheduler.recoveryReason == reason, scheduler.pendingCount == 0,
          !FileManager.default.fileExists(atPath: previous.workspace + "/file.txt") else {
        throw SandboxError("quarantined file-only purge changed execution admission or retained task files")
    }
    print("PASS native file-only Host: original data, edit/read, safe location and no command/GPU admission")
}
