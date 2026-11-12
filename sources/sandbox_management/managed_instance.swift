import Foundation
import SandboxCore
import SandboxRuntime

enum WorkspaceCheckpoint {
    static func withArchive<T>(directory: URL, id: String, sha256: String?, _ body: (URL) throws -> T) throws -> T {
        let archive = directory.appendingPathComponent("checkpoints/\(id).zip")
        guard let sha256, try WorkspaceArchive.digest(archive) == sha256 else { throw SandboxError("checkpoint integrity failure") }
        try WorkspaceArchive.read(archive); return try body(archive)
    }

}

/// Stable logical workspace, replaceable signed physical instance. Revisions
/// are published only from frozen bytes; no direct execution on the controller.
final class ManagedInstance: SandboxSession {
    let id: String
    private let operations = NSRecursiveLock()
    private let files = NSRecursiveLock()
    private let metadata = NSLock()
    private var record: NativeInstanceRecord
    private let factory: AppSandboxFactory
    private let toolchain: InstalledClang
    private var physical: AppSandboxSession?
    private let recordURL: URL
    private let environmentURL: URL
    let checkpointURL: URL
    init(id: String, directory: URL, factory: AppSandboxFactory, toolchain: InstalledClang, seedArchive: URL? = nil, networkClient: Bool = true, taskPolicy: TaskPolicy, name: String? = nil, sharedWorkspace: SharedWorkspace? = nil, dynamicScheduling: Bool = false) throws {
        self.id = id; self.factory = factory; self.toolchain = toolchain
        environmentURL = directory.appendingPathComponent("environments/\(id).json")
        record = NativeInstanceRecord(id: id)
        record.name = try NativeInstanceRecord.normalizedName(name)
        record.networkClient = networkClient
        record.sharedWorkspace = sharedWorkspace; record.dynamicScheduling = dynamicScheduling
        try taskPolicy.validate(); record.taskPolicy = taskPolicy
        record.ownedBundleIDs = []
        recordURL = directory.appendingPathComponent("instances/\(id).json")
        checkpointURL = directory.appendingPathComponent("checkpoints/\(id).zip")
        try persist { _ in }
        do {
            physical = try factory.create(logicalID: id, networkClient: networkClient, taskPolicy: taskPolicy, sharedWorkspace: sharedWorkspace, onAllocated: trackRevision)
            if let seedArchive { try physical!.upload(from: seedArchive) }
            try checkpoint()
            try persist { $0.state = .active; $0.physical = physical!.info; $0.revisions = 1 }
        } catch {
            try? physical?.close(); physical = nil
            try? persist { $0.state = .failed; $0.error = String(describing: error) }
            throw error
        }
    }
    init(starting source: NativeInstanceRecord, directory: URL, factory: AppSandboxFactory, toolchain: InstalledClang, taskPolicy: TaskPolicy) throws {
        id = source.id; record = source; self.factory = factory; self.toolchain = toolchain
        environmentURL = directory.appendingPathComponent("environments/\(source.id).json")
        recordURL = directory.appendingPathComponent("instances/\(id).json")
        checkpointURL = directory.appendingPathComponent("checkpoints/\(id).zip")
        guard let previous = source.physical else { throw SandboxError("instance has no original container to start") }
        try taskPolicy.validate()
        // Keep the old inactive record if validation/signing fails. No stale
        // capability is reused and no historical command is replayed.
        physical = try factory.start(previous, logicalID: id, networkClient: source.networkClient == true, taskPolicy: taskPolicy, sharedWorkspace: source.sharedWorkspace)
        do {
            try persist { $0.state = .active; $0.physical = physical!.info; $0.taskPolicy = taskPolicy; $0.error = nil }
        } catch { try? physical?.close(); physical = nil; throw error }
    }
    func configureDelegation(queue: ClusterTaskQueue) throws {
        guard record.dynamicScheduling == true, let shared = record.sharedWorkspace else { return }
        let session = try live()
        session.clusterTasks = queue
        let context = ClusterEnvironment(toolchain: toolchain,
            privateDirectories: [FileManager.default.homeDirectoryForCurrentUser.path, session.info.home, session.info.bundle],
            sharedDirectories: [shared.workspace.path, shared.home.path])
        session.clusterTask = { [weak self] command, environment in
            guard let self else { throw SandboxError("instance closed during cluster dispatch") }
            guard context.canTransfer(command, environment: environment) else { return nil }
            var task = ClusterTask(instanceID: self.id, workspace: shared, command: command, environment: environment,
                networkClient: self.summary.networkClient == true, taskPolicy: self.summary.taskPolicy!)
            task.sourceEnvironment = context
            return task
        }
    }
    func acknowledgeRecovery() throws { try live().acknowledgeRecovery() }
    var summary: NativeInstanceRecord {
        metadata.lock(); defer { metadata.unlock() }
        var result = record
        if result.state == .active, let failure = physical?.connectionError {
            result.state = .failed; result.error = failure
        }
        return result
    }
    func rename(_ name: String?) throws {
        let name = try NativeInstanceRecord.normalizedName(name)
        try persist { $0.name = name }
    }
    func requireLoopbackForward(_ id: String, enabled: Bool) throws {
        try persist { record in
            var ids = Set(record.loopbackForwardIDs ?? [])
            if enabled { ids.insert(id) } else { ids.remove(id) }
            record.loopbackForwardIDs = ids.isEmpty ? nil : ids.sorted()
        }
    }
    private func trackRevision(_ identifier: String) throws {
        try persist { $0.ownedBundleIDs?.append(identifier) }
    }
    private func persist(_ mutation: (inout NativeInstanceRecord) -> Void) throws {
        metadata.lock(); defer { metadata.unlock() }
        mutation(&record); record.updatedAt = Date(); try SafeFiles.write(record, to: recordURL)
    }
    private func live() throws -> AppSandboxSession {
        guard let physical else { throw SandboxError("instance is stopped or publication failed") }; return physical
    }
    private func checkpoint() throws {
        files.lock(); defer { files.unlock() }
        let archive = try live().downloadArchive(to: checkpointURL, path: nil)
        try persist { $0.checkpointFiles = archive.summary.files; $0.checkpointBytes = Int(archive.summary.bytes); $0.checkpointSHA256 = archive.sha256; $0.checkpointError = nil }
    }
    func download(to url: URL, path: String?) throws {
        if let path {
            files.lock(); defer { files.unlock() }
            try live().download(to: url, path: path); return
        }
        operations.lock(); defer { operations.unlock() }
        do { try checkpoint(); try WorkspaceArchive.copy(checkpointURL, to: url) }
        catch { try persist { $0.checkpointError = String(describing: error) }; throw error }
    }
    func upload(from url: URL) throws {
        operations.lock(); defer { operations.unlock() }
        files.lock(); defer { files.unlock() }
        try live().upload(from: url)
    }
    func installTests(from url: URL) throws {
        operations.lock(); defer { operations.unlock() }
        files.lock(); defer { files.unlock() }
        try live().upload(from: url, replacingTests: true)
    }
    func read(_ path: String) throws -> WorkspaceFile {
        files.lock(); defer { files.unlock() }; return try live().read(path)
    }
    func workspaceLocation(_ path: String) throws -> String {
        files.lock(); defer { files.unlock() }; return try live().workspaceLocation(path)
    }
    func trajectory(session: String?, after: String?) throws -> TrajectoryReply {
        files.lock(); defer { files.unlock() }; return try live().trajectory(session: session, after: after)
    }
    func listDirectory(_ path: String, after: String?) throws -> WorkspaceDirectory {
        files.lock(); defer { files.unlock() }; return try live().listDirectory(path, after: after)
    }
    func write(_ file: WorkspaceFile) throws {
        operations.lock(); defer { operations.unlock() }
        files.lock(); defer { files.unlock() }
        try live().write(file)
    }
    func export() throws -> [WorkspaceFile] {
        try WorkspaceArchive.temporary { url in
            try download(to: url, path: nil); return try WorkspaceArchive.collect(url)
        }
    }
    func prepareCommand(_ command: NativeCommand) throws -> NativeCommand {
        var result = command
        guard let executable = result.argv.first else { throw SandboxError("empty command") }
        let compiler = ["clang", "clang++", "/usr/bin/clang", "/usr/bin/clang++", toolchain.compiler, toolchain.cxxCompiler].contains(executable)
        switch executable {
        case "clang", "/usr/bin/clang": result.argv[0] = toolchain.compiler
        case "clang++", "/usr/bin/clang++": result.argv[0] = toolchain.cxxCompiler
        default:
            if !executable.contains("/") {
                if let path = toolchain.searchDirectories
                    .map({ $0 + "/" + executable }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                    result.argv[0] = path
                } else {
                    // The Host resolves this per-instance installation path;
                    // never inspect or run the operator's ~/.local/bin.
                    _ = try ConfinedWorkspace.components(executable)
                    guard let home = summary.physical?.home else { throw SandboxError("instance has no active environment") }
                    let developmentHome = summary.sharedWorkspace?.home.path ?? home + "/Library/Application Support/MetalSandbox/home"
                    result.argv[0] = developmentHome + "/.local/bin/" + executable
                }
            }
        }
        if compiler, !result.argv.contains("-isysroot"), !result.argv.contains(where: { $0.hasPrefix("--sysroot") || $0.hasPrefix("-isysroot") }) {
            result.argv.insert(contentsOf: ["-isysroot", toolchain.sdk], at: 1)
        }
        try result.validate(); return result
    }
    private func configuredEnvironment() throws -> [String: String] {
        FileManager.default.fileExists(atPath: environmentURL.path)
            ? try EnvironmentVariables.decode(SafeFiles.readRegular(environmentURL, limit: FramedChannel.messageLimit)) : [:]
    }
    func allowsParallel(_ command: NativeCommand) throws -> Bool {
        try live().allowsParallel(command, environment: configuredEnvironment())
    }
    func execute(_ command: NativeCommand) throws -> NativeResult { try execute(command, cancellation: CancellationToken()) }
    func execute(_ command: NativeCommand, cancellation: CancellationToken) throws -> NativeResult {
        try execute(command, cancellation: cancellation, onGranted: {})
    }
    func execute(_ command: NativeCommand, cancellation: CancellationToken, onGranted: () throws -> Void) throws -> NativeResult {
        guard !cancellation.isCancelled else { throw SandboxError("cancelled before execution") }
        let command = try prepareCommand(command)
        // Development binaries execute in place, including nested tool/helper
        // launches. The parent Host's kernel sandbox and global lease still apply.
        let environment = try configuredEnvironment()
        // Workspace writes already persist on disk. Only explicit snapshot,
        // full export and stop update the separate recovery archive.
        return try live().execute(command, cancellation: cancellation, environment: environment, onGranted: onGranted)
    }
    func close() throws {
        operations.lock(); defer { operations.unlock() }
        files.lock(); defer { files.unlock() }
        guard let physical else { return }
        try persist { $0.state = .stopping }
        do { try checkpoint() }
        catch { try persist { $0.checkpointError = String(describing: error) } }
        do {
            try physical.close(); self.physical = nil
            try persist { $0.state = .stopped }
        } catch {
            self.physical = nil
            try? persist { $0.state = .cleanupFailed; $0.error = String(describing: error) }
            throw error
        }
    }
}
