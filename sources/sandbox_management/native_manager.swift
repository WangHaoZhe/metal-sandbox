import Foundation
import Security
import SandboxCore
import SandboxRuntime

public final class NativeManager {
    private var clusterController: ClusterController?
    private var clusterConfiguration: ClusterConfiguration?
    private var loopbackForwards: LoopbackForwardRegistry!
    private let clusterTasks: ClusterTaskQueue
    private var clusterJobs: [String: (session: AppSandboxSession, token: CancellationToken, update: ClusterTaskUpdate)] = [:]
    private struct ReservedClusterTask {
        let session: AppSandboxSession
        let task: ClusterTask
        let reservation: ClusterReservation
    }
    private var clusterReservations: [String: ReservedClusterTask] = [:]
    private struct Entry { let session: ManagedInstance; let owner: SandboxHandle }
    private let directory: URL
    private let scheduler: ExecutionScheduler
    private let stateLease: FileLease
    private let factory: AppSandboxFactory
    private let toolchain: InstalledClang
    private let maxConcurrentInstances: Int
    private let operatorToken: String
    private let registry = SandboxRegistry()
    private let lock = NSRecursiveLock()
    private let creationLock = NSRecursiveLock()
    private let testPackageLock = NSLock()
    private let parallelExecutor = DispatchQueue(label: "metal-sandbox.native-parallel", attributes: .concurrent)
    private let work = DispatchGroup()
    private var accepting = true
    private var entries: [String: Entry] = [:]
    private var historical: [String: NativeInstanceRecord] = [:]
    private var executions: [String: NativeExecutionRecord] = [:]
    private var fileGates: [String: NSRecursiveLock] = [:]
    private var fileWorkers: [String: (session: AppSandboxSession, lastUsed: Date)] = [:]
    private let fileReaperQueue = DispatchQueue(label: "metal-sandbox.file-reaper")
    private var fileReaper: DispatchSourceTimer?
    private var executionHistory: [String: NativeExecutionBrief] = [:]
    private var cancellation: [String: CancellationToken] = [:]
    private var verificationOwners: [String: String] = [:]
    private var automaticParents = Set<String>()
    private let verificationQueue = DispatchQueue(label: "metal-sandbox.automatic-verification")
    private var verificationTimer: DispatchSourceTimer?

    public init(directory: URL, binDirectory: URL, taskPolicyURL: URL? = nil, clusterURL: URL? = nil, sharedRoot: String? = nil, maxConcurrentInstances: Int? = nil, clusterTransport: ClusterTransport = SSHClusterTransport(), coordinationDirectory: URL = Paths.coordination) throws {
        self.directory = directory
        try SafeFiles.secureDirectory(directory)
        stateLease = try FileLease(directory.appendingPathComponent("manager.lock"))
        for name in ["environments", "instances", "checkpoints", "executions", "runtimes", "toolchain_logs", "deleted_instances", "cleanup_audit", "test_packages", "verification_settings", "verification_results", "cluster_jobs"] {
            try SafeFiles.secureDirectory(directory.appendingPathComponent(name))
        }
        toolchain = try InstalledClang.resolve(logDirectory: directory.appendingPathComponent("toolchain_logs"))
        let policy = try taskPolicyURL.map { try SafeFiles.read(TaskPolicy.self, from: $0, limit: 128 * 1024) }
            ?? TaskPolicy.development(toolchain: toolchain)
        scheduler = try ExecutionScheduler(coordinationDirectory: coordinationDirectory, taskPolicy: policy)
        clusterTasks = try ClusterTaskQueue(directory: directory.appendingPathComponent("cluster_claims"))
        if try clusterTasks.hasUnfinishedClaims { try scheduler.requireInspection("remote execution claims survived service restart; inspect execution nodes before recovery") }
        factory = try AppSandboxFactory(binDirectory: binDirectory, directory: directory.appendingPathComponent("runtimes"), scheduler: scheduler)
        if let clusterURL {
            clusterConfiguration = try SafeFiles.read(ClusterConfiguration.self, from: clusterURL)
            try clusterConfiguration!.validate()
        } else if let sharedRoot {
            clusterConfiguration = ClusterConfiguration(localNodeID: "local", sharedRoot: sharedRoot, nodes: [])
            try clusterConfiguration!.validate()
        }
        guard clusterURL == nil || maxConcurrentInstances == nil else { throw SandboxError("set maxConcurrentInstances in the cluster configuration when using --cluster-config") }
        try ClusterConfiguration.validateInstanceLimit(maxConcurrentInstances)
        self.maxConcurrentInstances = clusterConfiguration?.maxConcurrentInstances ?? maxConcurrentInstances ?? 32
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SandboxError("cannot generate operator capability") }
        operatorToken = bytes.map { String(format: "%02x", $0) }.joined()
        // Restart rotates all management credentials and never reuses stale
        // scoped handles or attempts to kill a process using a persisted PID.
        try SafeFiles.writeData(Data(operatorToken.utf8), to: directory.appendingPathComponent("operator_token"))
        for path in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("instances"), includingPropertiesForKeys: nil) where path.pathExtension == "json" {
            var record = try SafeFiles.read(NativeInstanceRecord.self, from: path)
            try Self.validateID(record.id)
            if [.starting, .active, .publishing, .stopping].contains(record.state) {
                record.state = .interrupted; record.error = "manager restarted; no process replay; start reopens the original container, restore clones its checkpoint"
                try SafeFiles.write(record, to: path)
            }
            historical[record.id] = record
        }
        for path in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("executions"), includingPropertiesForKeys: nil) where path.pathExtension == "json" {
            var record = try SafeFiles.read(NativeExecutionRecord.self, from: path, limit: FramedChannel.messageLimit)
            if !record.isTerminal {
                record.state = "interrupted"; record.error = "manager restarted; execution not replayed"; record.finishedAt = Date()
                try SafeFiles.write(record, to: path)
            }
            executionHistory[record.id] = NativeExecutionBrief(record)
            if let state = record.automaticVerification?.state, ["waiting", "submitted"].contains(state) { automaticParents.insert(record.id) }
        }
        for path in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("cluster_jobs"), includingPropertiesForKeys: nil) where path.pathExtension == "json" {
            var update = try SafeFiles.read(ClusterTaskUpdate.self, from: path)
            if ["queued", "withdrawing", "running"].contains(update.state) {
                update.state = "failed"; update.error = "execution node restarted; cleanup requires operator inspection"
                update.cleanupConfirmed = false
                try SafeFiles.write(update, to: path)
                try scheduler.requireInspection(update.error!)
            }
        }
        let reaper = DispatchSource.makeTimerSource(queue: fileReaperQueue)
        reaper.schedule(deadline: .now() + 30, repeating: 30)
        reaper.setEventHandler { [weak self] in self?.reapIdleFiles() }
        fileReaper = reaper; reaper.resume()
        let timer = DispatchSource.makeTimerSource(queue: verificationQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.advanceVerifications(); self?.reapClusterReservations() }
        verificationTimer = timer; timer.resume()
        if let configuration = clusterConfiguration, clusterURL != nil {
            clusterController = try ClusterController(configuration: configuration, directory: directory, transport: clusterTransport,
                local: { [weak self] request in
                    guard let self else { return NativeControlReply(requestID: request.requestID) }
                    var request = request; request.operatorToken = request.handle == nil ? self.operatorToken : nil; request.localOnly = true
                    return self.handle(request)
                })
        }
        loopbackForwards = try LoopbackForwardRegistry(configuration: clusterConfiguration, transport: clusterTransport)
        clusterController?.loopbackForwards = loopbackForwards
    }
    private func fileGate(_ id: String) -> NSRecursiveLock {
        lock.lock(); defer { lock.unlock() }
        if let gate = fileGates[id] { return gate }
        let gate = NSRecursiveLock(); fileGates[id] = gate; return gate
    }
    private func closeFileWorker(_ id: String) throws {
        lock.lock(); let worker = fileWorkers.removeValue(forKey: id); lock.unlock()
        try worker?.session.close()
    }
    private func checkpointStopped(_ id: String, session: AppSandboxSession,
                                   archive: (url: URL, summary: WorkspaceArchive.Summary, sha256: String)? = nil) throws {
        let url = directory.appendingPathComponent("checkpoints/\(id).zip")
        do {
            let summary: WorkspaceArchive.Summary, digest: String
            if let archive {
                try WorkspaceArchive.copy(archive.url, to: url)
                summary = archive.summary; digest = archive.sha256
            } else {
                let received = try session.downloadArchive(to: url, path: nil)
                summary = received.summary; digest = received.sha256
            }
            lock.lock(); defer { lock.unlock() }
            guard var record = historical[id] else { throw SandboxError("instance changed during file operation") }
            record.checkpointFiles = summary.files; record.checkpointBytes = Int(summary.bytes)
            record.checkpointSHA256 = digest; record.checkpointError = nil; record.updatedAt = Date()
            try SafeFiles.write(record, to: directory.appendingPathComponent("instances/\(id).json")); historical[id] = record
        } catch {
            lock.lock(); defer { lock.unlock() }
            if var record = historical[id] {
                record.checkpointError = String(describing: error)
                try? SafeFiles.write(record, to: directory.appendingPathComponent("instances/\(id).json")); historical[id] = record
            }
            throw error
        }
    }
    private func withFiles<T>(_ request: NativeControlRequest, operation: SandboxOperation, checkpoint: Bool = true, _ body: (SandboxSession) throws -> T) throws -> T {
        guard let id = request.instanceID else { throw SandboxError("missing instanceID") }
        try Self.validateID(id)
        let gate = fileGate(id); gate.lock(); defer { gate.unlock() }
        if operation != .read {
            lock.lock(); let verifying = verificationOwners[id] != nil; lock.unlock()
            guard !verifying else { throw SandboxError("instance reserved for verification; read operations remain available") }
        }
        lock.lock(); let live = entries[id] != nil, source = historical[id]; lock.unlock()
        if live { return try body(registry.client(access(request, operation).1)) }
        try admin(request) // stopped instances never revive stale scoped handles
        guard let source, source.hasWorkspace, let physical = source.physical else {
            throw SandboxError("instance has no available workspace")
        }
        guard source.ownedBundleIDs?.contains(physical.bundleID) == true else { throw SandboxError("workspace ownership is incomplete") }
        lock.lock(); let others = Array(historical.values) + entries.values.map { $0.session.summary }; lock.unlock()
        guard !others.contains(where: { $0.id != id && (($0.ownedBundleIDs ?? []).contains(physical.bundleID) || $0.physical?.bundleID == physical.bundleID) }) else {
            throw SandboxError("workspace is also claimed by another instance")
        }
        lock.lock(); let cached = fileWorkers[id]?.session; lock.unlock()
        let session: AppSandboxSession
        if let cached { session = cached }
        else {
            session = try factory.start(physical, logicalID: id, networkClient: false, taskPolicy: source.taskPolicy ?? scheduler.taskPolicy, fileOnly: true, sharedWorkspace: source.sharedWorkspace)
            lock.lock(); fileWorkers[id] = (session, Date()); lock.unlock()
        }
        defer { lock.lock(); if fileWorkers[id] != nil { fileWorkers[id]?.lastUsed = Date() }; lock.unlock() }
        do {
            let result = try body(session)
            if checkpoint && operation == .export { try checkpointStopped(id, session: session) }
            return result
        } catch {
            if session.connectionError != nil { try? closeFileWorker(id) }
            throw error
        }
    }
    private func reapIdleFiles() {
        lock.lock(); let ids = Array(fileWorkers.keys); lock.unlock()
        for id in ids {
            let gate = fileGate(id); gate.lock(); defer { gate.unlock() }
            lock.lock(); let stale = fileWorkers[id].map { Date().timeIntervalSince($0.lastUsed) > 60 } ?? false; lock.unlock()
            if stale { try? closeFileWorker(id) }
        }
    }
    private static func validateID(_ id: String) throws {
        guard id.hasPrefix("sbx-"), UUID(uuidString: String(id.dropFirst(4))) != nil else { throw SandboxError("invalid sandbox ID") }
    }
    private func isOperator(_ request: NativeControlRequest) -> Bool {
        guard let token = request.operatorToken, token.utf8.count == operatorToken.utf8.count else { return false }
        return zip(token.utf8, operatorToken.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private func admin(_ request: NativeControlRequest) throws {
        guard isOperator(request) else { throw SandboxError("operator capability required") }
    }
    private func access(_ request: NativeControlRequest, _ operation: SandboxOperation) throws -> (Entry, SandboxHandle) {
        guard let id = request.instanceID else { throw SandboxError("missing instanceID") }
        lock.lock(); let entry = entries[id]; lock.unlock()
        guard let entry else { throw SandboxError("instance is not active", code: .instanceInactive) }
        let handle: SandboxHandle
        if isOperator(request) { handle = entry.owner }
        else {
            guard let supplied = request.handle, supplied.instanceID == id else { throw SandboxError("matching scoped capability required") }
            handle = supplied
        }
        try registry.validate(handle, operation: operation)
        return (entry, handle)
    }
    private func admission(allowWaiting: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { throw SandboxError("manager is shutting down") }
        if !allowWaiting, let reason = scheduler.recoveryReason { throw SandboxError("node quarantined: \(reason)") }
    }
    private func requireInstanceSlots(_ count: Int = 1, limit: Int? = nil) throws {
        try ClusterConfiguration.validateInstanceLimit(limit)
        let maximum = min(maxConcurrentInstances, limit ?? maxConcurrentInstances)
        guard maximum > 0 else { throw SandboxError("instance admission is disabled on this node") }
        lock.lock(); let live = entries.count; lock.unlock()
        guard count <= maximum - live else {
            throw SandboxError("active-instance capacity is full (\(live)/\(maximum))", code: .instanceCapacityUnavailable)
        }
    }
    private func create(seedArchive: URL? = nil, networkClient: Bool = true, taskPolicy: TaskPolicy? = nil, environment: [String: String] = [:], name: String? = nil, dynamicScheduling: Bool = false, instanceLimit: Int? = nil) throws -> NativeInstanceRecord {
        creationLock.lock(); defer { creationLock.unlock() }
        try admission()
        try requireInstanceSlots(limit: instanceLimit)
        let policy = taskPolicy ?? scheduler.taskPolicy
        try policy.validate()
        try EnvironmentVariables.validate(environment)
        let id = "sbx-" + UUID().uuidString.lowercased()
        let shared = try dynamicScheduling ? clusterConfiguration?.sharedRoot.map {
            try SharedWorkspace(root: $0, instanceID: id, storageNodeID: clusterConfiguration?.localNodeID ?? "local")
        } : nil
        guard !dynamicScheduling || shared != nil else { throw SandboxError("dynamic scheduling requires a configured shared root") }
        if let shared {
            try shared.validate(root: clusterConfiguration?.sharedRoot)
            try shared.prepare()
        }
        try SafeFiles.write(environment, to: environmentURL(id))
        let session = try ManagedInstance(id: id, directory: directory, factory: factory, toolchain: toolchain, seedArchive: seedArchive, networkClient: networkClient, taskPolicy: policy, name: name, sharedWorkspace: shared, dynamicScheduling: dynamicScheduling)
        try session.configureDelegation(queue: clusterTasks)
        do {
            let owner = try registry.register(session)
            lock.lock(); defer { lock.unlock() }
            guard accepting else { try registry.client(owner).close(); throw SandboxError("shutdown during creation") }
            entries[id] = Entry(session: session, owner: owner)
            return session.summary
        } catch { try? session.close(); throw error }
    }
    private func environmentURL(_ id: String) -> URL { directory.appendingPathComponent("environments/\(id).json") }
    private func loadEnvironment(_ id: String) throws -> [String: String] {
        let url = environmentURL(id)
        return FileManager.default.fileExists(atPath: url.path)
            ? try EnvironmentVariables.decode(SafeFiles.readRegular(url, limit: FramedChannel.messageLimit)) : [:]
    }
    private func removeInstanceConfiguration(_ id: String) throws {
        for folder in ["environments", "verification_settings"] {
            let url = directory.appendingPathComponent("\(folder)/\(id).json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    private func record(_ id: String) throws -> NativeExecutionRecord {
        guard UUID(uuidString: id) != nil else { throw SandboxError("invalid execution ID") }
        lock.lock(); var current = executions[id]
        if let token = cancellation[id] { current?.schedulerWaitSeconds = token.queueWait.seconds }
        lock.unlock()
        return try current ?? SafeFiles.read(NativeExecutionRecord.self, from: directory.appendingPathComponent("executions/\(id).json"), limit: FramedChannel.messageLimit)
    }
    private func start(_ request: NativeControlRequest) throws -> NativeInstanceRecord {
        try admin(request)
        creationLock.lock(); defer { creationLock.unlock() }
        try admission()
        guard let id = request.instanceID else { throw SandboxError("missing instanceID") }
        try Self.validateID(id)
        let gate = fileGate(id); gate.lock(); defer { gate.unlock() }
        try closeFileWorker(id)
        lock.lock()
        let source = historical[id], active = entries[id] != nil
        let pending = cancellation.keys.contains { executions[$0]?.instanceID == id }
        let others = Array(historical.values) + entries.values.map { $0.session.summary }
        lock.unlock()
        guard !active, !pending, let source,
              source.canStart, let physical = source.physical else {
            throw SandboxError("start requires an inactive original instance, no pending commands and a free instance slot")
        }
        try requireInstanceSlots(limit: request.instanceLimit)
        guard source.ownedBundleIDs?.contains(physical.bundleID) == true else {
            throw SandboxError("original container ownership is incomplete; cannot safely start")
        }
        guard !others.contains(where: { $0.id != id && (($0.ownedBundleIDs ?? []).contains(physical.bundleID) || $0.physical?.bundleID == physical.bundleID) }) else {
            throw SandboxError("original container is also claimed by another instance")
        }
        let session = try ManagedInstance(starting: source, directory: directory, factory: factory, toolchain: toolchain,
                                          taskPolicy: source.taskPolicy ?? scheduler.taskPolicy)
        try session.configureDelegation(queue: clusterTasks)
        do {
            let owner = try registry.register(session, reactivating: true)
            lock.lock(); defer { lock.unlock() }
            guard accepting else { try registry.client(owner).close(); throw SandboxError("shutdown during startup") }
            entries[id] = Entry(session: session, owner: owner)
            historical.removeValue(forKey: id)
            return session.summary
        } catch {
            try? session.close()
            lock.lock(); historical[id] = session.summary; lock.unlock()
            throw error
        }
    }
    private func save(_ record: NativeExecutionRecord) throws {
        try SafeFiles.write(record, to: directory.appendingPathComponent("executions/\(record.id).json"))
        lock.lock(); executions[record.id] = record; executionHistory[record.id] = NativeExecutionBrief(record)
        if executions.count > 128, let oldest = executions.values.filter({ $0.isTerminal }).min(by: { $0.createdAt < $1.createdAt }) {
            executions.removeValue(forKey: oldest.id)
        }
        lock.unlock()
    }
    private func executionAccess(_ request: NativeControlRequest) throws -> NativeExecutionRecord {
        guard let id = request.executionID else { throw SandboxError("missing executionID") }
        let result = try record(id)
        if !isOperator(request) {
            guard request.instanceID == result.instanceID else { throw SandboxError("execution belongs to another instance") }
            _ = try access(request, .exec)
        }
        return result
    }
    private func submit(_ request: NativeControlRequest, verificationID: String? = nil, agentID: String? = nil) throws -> NativeExecutionRecord {
        try admission(allowWaiting: true)
        let (entry, handle) = try access(request, .exec)
        let gate = fileGate(entry.session.id); gate.lock(); defer { gate.unlock() }
        guard let command = request.command else { throw SandboxError("missing command") }
        let prepared = try entry.session.prepareCommand(command)
        if prepared.agentSession == true { try admin(request) }
        if prepared.verification == true { try admin(request) }
        guard request.testPackageSHA256 == nil || prepared.verification == true else { throw SandboxError("test archive requires a verification command") }
        let archive = try request.testPackageSHA256.map { try testArchive($0) }
        let parallel = try entry.session.allowsParallel(prepared)
        var record = NativeExecutionRecord(id: verificationID ?? UUID().uuidString.lowercased(), instanceID: entry.session.id,
                                           command: prepared, scheduling: parallel ? "parallel" : "serial")
        record.agentExecutionID = agentID; record.testPackageSHA256 = request.testPackageSHA256
        if prepared.agentSession == true {
            let settings = try verificationSettings(entry.session.id)
            if settings.enabled {
                _ = try testArchive(settings.testPackageSHA256!)
                record.automaticVerification = AutomaticVerification(settings: settings)
            }
        }
        let token = CancellationToken(), queued = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        guard accepting, cancellation.count < max(64, maxConcurrentInstances) else { throw SandboxError("execution admission closed or queue full") }
        if let agentID {
            guard try self.record(agentID).automaticVerification?.state == "waiting" else {
                throw SandboxError("automatic verification was cancelled before submission")
            }
        }
        guard verificationOwners[entry.session.id] == nil else { throw SandboxError("instance reserved for verification") }
        if prepared.verification == true {
            guard instanceIdle(entry.session.id) else { throw SandboxError("verification waits for this instance's commands to finish") }
        }
        guard executionHistory[record.id] == nil else { throw SandboxError("execution already registered") }
        try save(record); cancellation[record.id] = token; work.enter()
        if prepared.verification == true { verificationOwners[entry.session.id] = record.id }
        if record.automaticVerification != nil { automaticParents.insert(record.id) }
        scheduler.registerPending(token, ownerID: entry.session.id, parallel: parallel)
        let initial = record
        parallelExecutor.async { [self] in
            defer {
                scheduler.discardPending(token); lock.lock()
                cancellation.removeValue(forKey: initial.id)
                if verificationOwners[entry.session.id] == initial.id { verificationOwners.removeValue(forKey: entry.session.id) }
                lock.unlock(); work.leave()
            }
            var finished = initial
            do {
                guard !token.isCancelled else { throw SandboxError("cancelled before launch") }
                if let archive {
                    let gate = fileGate(entry.session.id); gate.lock(); defer { gate.unlock() }
                    try entry.session.installTests(from: archive)
                }
                guard !token.isCancelled else { throw SandboxError("cancelled before launch") }
                let wait = Double(DispatchTime.now().uptimeNanoseconds - queued) / 1e9
                var result = try registry.client(handle).execute(prepared, cancellation: token) {
                    lock.lock(); defer { lock.unlock() }
                    finished.automaticVerification = try self.record(initial.id).automaticVerification
                    finished.state = "running"; finished.startedAt = Date(); try save(finished)
                }
                result.queueWaitSeconds += wait
                finished.result = result
                finished.state = result.outcome.reason == .exited && result.outcome.exitCode == 0 ? "succeeded" : "failed"
                if result.outcome.reason == .launchFailed {
                    finished.error = result.outcome.launchError ?? "command failed before process creation"
                } else if result.outcome.reason == .timedOut {
                    finished.error = "command timed out; process group cleaned up; subsequent commands may continue"
                } else if result.outcome.reason == .cancelled {
                    finished.state = "cancelled"
                    finished.error = "command cancelled; process group cleaned up; subsequent commands may continue"
                } else if result.outcome.reason == .signalled {
                    finished.error = "command terminated by signal \(result.outcome.terminationSignal ?? 0); process group cleaned up; subsequent commands may continue"
                } else if result.outcome.reason == .outputLimit {
                    finished.error = "command output limit exceeded; process group cleaned up; subsequent commands may continue"
                }
            } catch {
                if let uncertain = error as? UncertainExecution { finished.result = uncertain.result }
                finished.state = token.isCancelled ? "cancelled" : "failed"; finished.error = String(describing: error)
            }
            finished.finishedAt = Date()
            finished.schedulerWaitSeconds = token.queueWait.seconds
            do {
                if prepared.verification == true, scheduler.recoveryReason == nil, finished.result != nil {
                    do {
                        var after: String?
                        repeat {
                            let page = try entry.session.listDirectory("tests", after: after)
                            if page.entries.contains(where: { $0.name == "metrics.json" }) {
                                try entry.session.download(to: directory.appendingPathComponent("verification_results/\(initial.id).zip"), path: "tests/metrics.json")
                                finished.metricsSaved = true; break
                            }
                            after = page.nextAfter
                        } while after != nil
                    } catch { finished.state = "failed"; finished.error = "cannot save verification metrics: \(error)" }
                }
                lock.lock(); defer { lock.unlock() }
                finished.automaticVerification = try self.record(initial.id).automaticVerification
                try save(finished)
            }
            catch { try? scheduler.requireInspection("cannot persist execution completion: \(error)") }
        }
        return record
    }

    private func verificationSettings(_ id: String) throws -> VerificationSettings {
        let url = directory.appendingPathComponent("verification_settings/\(id).json")
        let settings = try FileManager.default.fileExists(atPath: url.path)
            ? SafeFiles.read(VerificationSettings.self, from: url) : VerificationSettings()
        try settings.validate(); return settings
    }
    private func saveVerificationSettings(_ settings: VerificationSettings, id: String) throws {
        try settings.validate()
        try SafeFiles.write(settings, to: directory.appendingPathComponent("verification_settings/\(id).json"))
    }
    private func testArchive(_ hash: String) throws -> URL {
        try VerificationSettings(testPackageSHA256: hash).validate()
        let url = directory.appendingPathComponent("test_packages/\(hash)/tests.zip")
        guard try TaskPackage.testsFingerprint(url) == hash else { throw SandboxError("saved tests integrity failure") }
        return url
    }
    private func instanceIdle(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let counts = scheduler.counts.byOwner
        return !cancellation.keys.contains { executions[$0]?.instanceID == id }
            && counts[id, default: ExecutionCounts()].total == 0
            && (entries[id]?.session.summary.physical.map { counts[$0.bundleID, default: ExecutionCounts()].total } ?? 0) == 0
    }
    private func submitVerification(_ request: NativeControlRequest, verificationID: String? = nil, agentID: String? = nil) throws -> NativeExecutionRecord {
        guard let id = request.instanceID else { throw SandboxError("missing instanceID") }
        var request = request
        if request.testPackageSHA256 == nil { request.testPackageSHA256 = try verificationSettings(id).testPackageSHA256 }
        let timeout = try request.verificationTimeout ?? verificationSettings(id).timeoutSeconds
        var command = NativeCommand(["/bin/bash", "./test.sh"], cwd: "tests", timeoutSeconds: timeout)
        command.verification = true
        request.command = command
        return try submit(request, verificationID: verificationID, agentID: agentID)
    }
    private func attachVerification(_ request: NativeControlRequest, executionID: String) throws -> NativeExecutionRecord {
        lock.lock(); defer { lock.unlock() }
        var parent = try record(executionID)
        guard parent.instanceID == request.instanceID, parent.command.agentSession == true,
              parent.automaticVerification == nil, !["cancelled", "interrupted"].contains(parent.state) else {
            throw SandboxError("automatic verification requires an uncancelled agent execution without a registered verifier")
        }
        var settings = try verificationSettings(parent.instanceID)
        settings.testPackageSHA256 = request.testPackageSHA256 ?? settings.testPackageSHA256
        settings.enabled = true; settings.timeoutSeconds = request.verificationTimeout ?? settings.timeoutSeconds
        try settings.validate(); _ = try testArchive(settings.testPackageSHA256!)
        parent.automaticVerification = AutomaticVerification(settings: settings)
        try save(parent); automaticParents.insert(parent.id); return parent
    }
    private func cancelAutomaticVerification(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var parent = try record(id)
        guard var plan = parent.automaticVerification else { return }
        if plan.state == "submitted", try record(plan.executionID).isTerminal {
            automaticParents.remove(id); return
        }
        cancellation[plan.executionID]?.cancel()
        if ["waiting", "submitted"].contains(plan.state) {
            plan.state = "cancelled"; plan.error = "cancelled by operator"
            parent.automaticVerification = plan; try save(parent)
        }
        automaticParents.remove(id)
    }
    private func cancelAutomaticVerifications(instanceID: String) throws {
        lock.lock(); defer { lock.unlock() }
        for id in Array(automaticParents) where executionHistory[id]?.instanceID == instanceID {
            try cancelAutomaticVerification(id)
        }
    }
    private func advanceVerifications() {
        lock.lock(); let ids = accepting ? Array(automaticParents) : []; lock.unlock()
        for id in ids {
            do {
                var parent = try record(id)
                guard var plan = parent.automaticVerification else { continue }
                if plan.state == "submitted" {
                    if try record(plan.executionID).isTerminal {
                        lock.lock(); automaticParents.remove(id); lock.unlock()
                    }
                    continue
                }
                guard plan.state == "waiting", parent.isTerminal else { continue }
                lock.lock(); let registered = executionHistory[plan.executionID] != nil; lock.unlock()
                if registered {
                    plan.state = "submitted"
                } else if ["cancelled", "interrupted"].contains(parent.state) || parent.result == nil {
                    plan.state = parent.state == "cancelled" ? "cancelled" : "blocked"
                    plan.error = "agent completion or process cleanup was not confirmed"
                } else if scheduler.recoveryReason != nil {
                    continue
                } else {
                    lock.lock()
                    let live = entries[parent.instanceID] != nil
                    let room = (live || entries.count < maxConcurrentInstances) && cancellation.count < max(64, maxConcurrentInstances)
                    lock.unlock()
                    if !room { continue }
                    if !live {
                        creationLock.lock(); defer { creationLock.unlock() }
                        let gate = fileGate(parent.instanceID); gate.lock(); defer { gate.unlock() }
                        guard try record(id).automaticVerification?.state == "waiting" else { continue }
                        lock.lock(); let needsStart = entries[parent.instanceID] == nil; lock.unlock()
                        if needsStart {
                            var startRequest = NativeControlRequest("start"); startRequest.operatorToken = operatorToken; startRequest.instanceID = parent.instanceID
                            _ = try start(startRequest)
                        }
                    }
                    let gate = fileGate(parent.instanceID); gate.lock(); defer { gate.unlock() }
                    lock.lock(); let ready = accepting && instanceIdle(parent.instanceID) && verificationOwners[parent.instanceID] == nil; lock.unlock()
                    if !ready { continue }
                    parent = try record(id)
                    guard parent.automaticVerification?.state == "waiting" else { continue }
                    lock.lock(); let existing = executionHistory[plan.executionID]; lock.unlock()
                    if existing == nil {
                        var request = NativeControlRequest("verify"); request.operatorToken = operatorToken; request.instanceID = parent.instanceID
                        request.testPackageSHA256 = plan.settings.testPackageSHA256; request.verificationTimeout = plan.settings.timeoutSeconds
                        _ = try submitVerification(request, verificationID: plan.executionID, agentID: parent.id)
                    }
                    plan.state = "submitted"
                }
                do {
                    lock.lock(); defer { lock.unlock() }
                    let cancelled = try record(id).automaticVerification?.state == "cancelled"
                    if !cancelled { parent.automaticVerification = plan; try save(parent) }
                }
                if plan.state != "submitted" { lock.lock(); automaticParents.remove(id); lock.unlock() }
            } catch let error as SandboxError where error.code == .instanceCapacityUnavailable {
                continue
            } catch {
                do {
                    lock.lock(); defer { lock.unlock() }
                    var parent = try record(id)
                    if parent.automaticVerification?.state != "cancelled" {
                        parent.automaticVerification?.state = "blocked"
                        parent.automaticVerification?.error = String(describing: error)
                        try save(parent)
                    }
                    automaticParents.remove(id)
                } catch { try? scheduler.requireInspection("cannot persist automatic verification: \(error)") }
            }
        }
    }
    private func stop(_ request: NativeControlRequest, cancelFollowingVerification: Bool = true) throws -> NativeInstanceRecord {
        creationLock.lock(); defer { creationLock.unlock() }
        guard let id = request.instanceID else { throw SandboxError("missing instanceID") }
        let gate = fileGate(id); gate.lock(); defer { gate.unlock() }
        let (entry, handle) = try access(request, .stop)
        defer {
            lock.lock(); entries.removeValue(forKey: entry.session.id); historical[entry.session.id] = entry.session.summary; lock.unlock()
        }
        if cancelFollowingVerification { try cancelAutomaticVerifications(instanceID: id) }
        lock.lock()
        for (id, token) in cancellation where executions[id]?.instanceID == entry.session.id { token.cancel() }
        lock.unlock()
        do { try registry.client(handle).close() }
        catch { try? scheduler.requireInspection("instance cleanup failed: \(error)"); throw error }
        return entry.session.summary
    }
    private func delete(_ request: NativeControlRequest) throws -> NativeInstanceRecord {
        try admin(request)
        guard request.confirmed == true, let id = request.instanceID else { throw SandboxError("delete requires ID and explicit confirmation") }
        try Self.validateID(id)
        // Serialize deletion with restore's snapshot read and all admission.
        // Never cancel another task to make a deletion fit.
        creationLock.lock(); defer { creationLock.unlock() }
        let gate = fileGate(id); gate.lock(); defer { gate.unlock() }
        try closeFileWorker(id)
        lock.lock()
        // Deleting an inactive instance is file maintenance, not execution
        // admission. Keep node quarantine intact while allowing its cleanup.
        let accepting = self.accepting, active = entries[id] != nil, sourceRecord = historical[id]
        let pending = cancellation.keys.contains { executions[$0]?.instanceID == id }
        lock.unlock()
        guard accepting else { throw SandboxError("manager is shutting down") }
        guard !active, !pending else { throw SandboxError("stop this instance and wait for its executions before permanent deletion") }
        guard try !clusterTasks.hasClaim(instanceID: id) else { throw SandboxError("remote task cleanup is unconfirmed; inspect execution nodes and recover before deletion") }
        let recordURL = directory.appendingPathComponent("instances/\(id).json")
        let auditURL = directory.appendingPathComponent("deleted_instances/\(id).json")
        if FileManager.default.fileExists(atPath: auditURL.path) {
            var completed = try SafeFiles.read(NativeInstanceRecord.self, from: auditURL)
            guard completed.id == id, completed.state == .deleted else { throw SandboxError("invalid deletion audit") }
            // Retry completed deletions by removing only validated empty
            // shells. Do not recreate a Host or delete unexpected new data.
            guard let owned = completed.ownedBundleIDs, Set(owned).count == owned.count, owned.count >= completed.revisions,
                  completed.physical.map({ owned.contains($0.bundleID) }) ?? true else { throw SandboxError("incomplete physical ownership journal") }
            for other in try allRecords() where other.id != id {
                let claims = Set((other.ownedBundleIDs ?? []) + [other.physical?.bundleID].compactMap { $0 })
                guard claims.isDisjoint(with: owned) else { throw SandboxError("completed deletion conflicts with another instance") }
            }
            var warnings: [String] = []
            for identifier in owned {
                do { try ContainerShell.remove(identifier) }
                catch let denied as ContainerShellPermissionDenied { warnings.append(denied.description) }
            }
            try removeInstanceConfiguration(id)
            completed.cleanupWarnings = warnings
            try SafeFiles.write(completed, to: auditURL)
            if FileManager.default.fileExists(atPath: recordURL.path) { try FileManager.default.removeItem(at: recordURL) }
            lock.lock(); historical.removeValue(forKey: id); lock.unlock()
            return completed
        }
        guard var source = sourceRecord, source.canDelete else {
            throw SandboxError("delete requires an inactive instance")
        }
        guard let owned = source.ownedBundleIDs, Set(owned).count == owned.count,
              owned.count >= source.revisions else { throw SandboxError("incomplete physical ownership journal; deletion refused") }
        for other in try allRecords() where other.id != id {
            let claims = Set((other.ownedBundleIDs ?? []) + [other.physical?.bundleID].compactMap { $0 })
            guard claims.isDisjoint(with: owned) else { throw SandboxError("physical identity is also claimed by another instance") }
        }
        for identifier in owned { try AppSandboxFactory.validateInstanceIdentifier(identifier) }
        if let physical = source.physical, !owned.contains(physical.bundleID) { throw SandboxError("physical identity is not owned by this instance") }
        source.ownedBundleIDs = owned; source.state = .deleting; source.updatedAt = Date()
        try SafeFiles.write(source, to: recordURL)
        lock.lock(); historical[id] = source; lock.unlock()
        do {
            var warnings: [String] = []
            for identifier in owned {
                if let warning = try factory.purge(identifier, logicalID: id, sharedWorkspace: source.sharedWorkspace,
                    removeSharedFiles: source.sharedWorkspace != nil) { warnings.append(warning) }
            }
            let checkpoint = directory.appendingPathComponent("checkpoints/\(id).zip")
            if FileManager.default.fileExists(atPath: checkpoint.path) { try FileManager.default.removeItem(at: checkpoint) }
            try removeInstanceConfiguration(id)
            source.state = .deleted; source.updatedAt = Date(); source.error = nil
            source.checkpointBytes = 0; source.checkpointFiles = 0; source.checkpointSHA256 = nil
            source.cleanupWarnings = warnings
            try SafeFiles.write(source, to: auditURL)
            try FileManager.default.removeItem(at: recordURL)
            lock.lock(); historical.removeValue(forKey: id); lock.unlock()
            return source
        } catch {
            source.state = .deleteFailed; source.updatedAt = Date(); source.error = "deletion incomplete: \(error)"
            try? SafeFiles.write(source, to: recordURL)
            lock.lock(); historical[id] = source; lock.unlock()
            throw error
        }
    }
    private func allRecords() throws -> [NativeInstanceRecord] {
        lock.lock()
        var result = Array(historical.values) + entries.values.map { $0.session.summary }
        lock.unlock()
        for url in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("deleted_instances"), includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            result.append(try SafeFiles.read(NativeInstanceRecord.self, from: url))
        }
        return result
    }
    private func cleanup(_ request: NativeControlRequest) throws -> [NativeCleanupItem] {
        try admin(request)
        creationLock.lock(); defer { creationLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        try admission()
        guard entries.isEmpty, cancellation.isEmpty, clusterJobs.isEmpty, clusterReservations.isEmpty else { throw SandboxError("cleanup requires all instances stopped and the execution queue idle") }
        let records = try allRecords()
        let currentClaims = Set(historical.values.flatMap { ($0.ownedBundleIDs ?? []) + [$0.physical?.bundleID].compactMap { $0 } })
        let unclaimed = request.operation == "cleanup-unclaimed"
        let ids: [String]
        if unclaimed {
            guard records.allSatisfy({ record in record.ownedBundleIDs.map { $0.count >= record.revisions } == true }) else {
                throw SandboxError("incomplete physical ownership journal; cannot safely identify unclaimed runtimes")
            }
            let claims = Set(records.flatMap { ($0.ownedBundleIDs ?? []) + [$0.physical?.bundleID].compactMap { $0 } })
            ids = try factory.allocatedIdentifiers().filter { !claims.contains($0) }
        } else {
            var completed = records.filter { $0.state == .deleted }.flatMap { ($0.ownedBundleIDs ?? []) + [$0.physical?.bundleID].compactMap { $0 } }
            for url in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("cleanup_audit"), includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                let audit = try SafeFiles.read([NativeCleanupItem].self, from: url)
                completed += audit.filter { ["removed", "data-removed-shell-retained"].contains($0.state) }.map { $0.bundleID }
            }
            ids = Array(Set(completed)).sorted()
        }
        guard Set(ids).isDisjoint(with: currentClaims) else { throw SandboxError("cleanup identity conflicts with a retained instance") }
        let selected = request.bundleIDs ?? (unclaimed ? [] : ids)
        guard Set(selected).count == selected.count, Set(selected).isSubset(of: ids) else { throw SandboxError("cleanup selection is stale or not eligible; preview again") }
        if request.confirmed != true { return ids.map { NativeCleanupItem(bundleID: $0, source: unclaimed ? "unclaimed-runtime" : "deletion-audit") } }
        guard !unclaimed || !selected.isEmpty else { throw SandboxError("select exact --bundle-id values from the cleanup preview") }
        var results: [NativeCleanupItem] = []
        for id in selected {
            do {
                if unclaimed, let warning = try factory.purge(id) {
                    results.append(NativeCleanupItem(bundleID: id, source: "unclaimed-runtime", state: "data-removed-shell-retained", error: warning))
                } else {
                    try ContainerShell.remove(id)
                    results.append(NativeCleanupItem(bundleID: id, source: unclaimed ? "unclaimed-runtime" : "deletion-audit", state: "removed"))
                }
            } catch { results.append(NativeCleanupItem(bundleID: id, source: unclaimed ? "unclaimed-runtime" : "deletion-audit", state: "failed", error: String(describing: error))) }
        }
        try SafeFiles.write(results, to: directory.appendingPathComponent("cleanup_audit/\(UUID().uuidString.lowercased()).json"))
        return results
    }
    public var status: NativeServiceStatus {
        lock.lock(); let live = entries.count; lock.unlock()
        let counts = scheduler.counts
        var status = NativeServiceStatus(activeInstances: live, executionCounts: counts.total, recoveryReason: scheduler.recoveryReason,
                                   stateDirectory: directory.path, toolchain: toolchain, taskPolicy: scheduler.taskPolicy, maxConcurrentInstances: maxConcurrentInstances)
        status.crossNodeSchedulingEnabled = clusterConfiguration?.crossNodeSchedulingEnabled != false
        status.acceptedSchedulingPool = clusterConfiguration?.schedulingPool
        return status
    }
    private func validateIncomingPool(_ task: ClusterTask) throws {
        guard let pool = task.schedulingPool else { throw SandboxError("cluster task is missing its scheduling pool") }
        try ClusterConfiguration.validatePool(pool)
        lock.lock(); let owned = entries[task.instanceID] != nil || historical[task.instanceID] != nil; lock.unlock()
        if owned { return }
        guard clusterConfiguration?.crossNodeSchedulingEnabled != false else { throw SandboxError("cross-node scheduling is disabled on the execution node") }
        if let accepted = clusterConfiguration?.schedulingPool, accepted != pool {
            throw SandboxError("execution node rejects scheduling pool: \(pool)")
        }
    }
    private func reserveClusterTask(_ task: ClusterTask) throws -> ClusterReservation? {
        try admission()
        try validateIncomingPool(task)
        guard UUID(uuidString: task.id) != nil, task.instanceID == task.workspace.instanceID else { throw SandboxError("invalid cluster task identity") }
        try task.workspace.validate(root: clusterConfiguration?.sharedRoot)
        try task.workspace.verify()
        try task.command.validate(); try EnvironmentVariables.validate(task.environment); try task.taskPolicy.validate()
        _ = try task.prepared(on: toolchain)
        guard task.command.agentSession != true else { throw SandboxError("agent sessions cannot migrate") }
        lock.lock()
        let existing = clusterReservations.values.first { $0.task.id == task.id }
        if clusterJobs[task.id] != nil { lock.unlock(); return nil }
        let previous = directory.appendingPathComponent("cluster_jobs/\(task.id).json")
        if FileManager.default.fileExists(atPath: previous.path) {
            do {
                let update = try SafeFiles.read(ClusterTaskUpdate.self, from: previous)
                if update.state != "withdrawn" || update.cleanupConfirmed != true { lock.unlock(); return nil }
            } catch { lock.unlock(); throw error }
        }
        lock.unlock()
        if let existing { return existing.reservation }
        guard let reservation = scheduler.reserveSerial(taskID: task.id) else { return nil }
        let session: AppSandboxSession
        do {
            session = try factory.create(logicalID: task.instanceID, networkClient: task.networkClient,
                taskPolicy: task.taskPolicy, sharedWorkspace: task.workspace)
        } catch { scheduler.releaseReservation(reservation.id); throw error }
        lock.lock(); clusterReservations[reservation.id] = ReservedClusterTask(session: session, task: task, reservation: reservation); lock.unlock()
        return reservation
    }
    private func commitClusterTask(_ task: ClusterTask, reservation: String) throws -> ClusterTaskUpdate {
        let path = directory.appendingPathComponent("cluster_jobs/\(task.id).json")
        guard UUID(uuidString: task.id) != nil else { throw SandboxError("invalid cluster task ID") }
        lock.lock(); defer { lock.unlock() }
        if let job = clusterJobs[task.id] {
            guard job.update.reservationID == reservation else { throw SandboxError("cluster task reservation differs") }
            return job.update
        }
        if FileManager.default.fileExists(atPath: path.path) {
            let previous = try SafeFiles.read(ClusterTaskUpdate.self, from: path)
            if previous.state == "withdrawing" { throw SandboxError("cluster reservation is being withdrawn", code: .clusterReservationExpired) }
            if previous.state == "withdrawn", previous.reservationID == reservation { throw SandboxError("cluster reservation was withdrawn", code: .clusterReservationExpired) }
            if previous.state != "withdrawn" {
                guard previous.reservationID == reservation else { throw SandboxError("cluster task reservation differs") }
                return previous
            }
        }
        guard accepting else { throw SandboxError("execution node is shutting down") }
        try validateIncomingPool(task)
        guard let reserved = clusterReservations[reservation], reserved.reservation.expiresAt >= Date() else {
            throw SandboxError("cluster reservation expired before commit", code: .clusterReservationExpired)
        }
        guard try JSON.data(reserved.task) == JSON.data(task) else { throw SandboxError("cluster commit differs from reserved task") }
        let prepared = try task.prepared(on: toolchain)
        let session = reserved.session
        clusterReservations.removeValue(forKey: reservation)
        let token = CancellationToken()
        var initial = ClusterTaskUpdate(taskID: task.id, state: "queued")
        initial.reservationID = reservation
        try SafeFiles.write(initial, to: path)
        clusterJobs[task.id] = (session, token, initial); work.enter()
        parallelExecutor.async { [self] in
            defer { work.leave() }
            var result = ClusterTaskUpdate(taskID: task.id, state: "finished")
            result.reservationID = reservation
            var launched = false
            do {
                result.result = try session.execute(prepared.command, cancellation: token, environment: prepared.environment,
                    reservationID: reservation, onGranted: {
                        self.lock.lock(); defer { self.lock.unlock() }
                        var running = initial; running.state = "running"
                        try SafeFiles.write(running, to: path)
                        self.clusterJobs[task.id]?.update = running; launched = true
                    })
                try session.close()
                result.cleanupConfirmed = true
                _ = try factory.purge(session.id, logicalID: task.instanceID)
            } catch {
                result.state = "failed"; result.error = String(describing: error)
                if let uncertain = error as? UncertainExecution { result.result = uncertain.result }
                do {
                    try session.close()
                    result.cleanupConfirmed = !launched || result.result?.outcome.requiresInspection == false
                    _ = try factory.purge(session.id, logicalID: task.instanceID)
                }
                catch {
                    result.cleanupConfirmed = false
                    try? scheduler.requireInspection("cluster Host cleanup uncertain: \(error)")
                }
                scheduler.releaseReservation(reservation)
                lock.lock(); let withdrawing = clusterJobs[task.id]?.update.state == "withdrawing"; lock.unlock()
                if withdrawing && !launched && result.cleanupConfirmed == true { result.state = "withdrawn" }
            }
            lock.lock(); defer { lock.unlock() }
            clusterJobs[task.id]?.update = result
            do { try SafeFiles.write(result, to: path); clusterJobs.removeValue(forKey: task.id) }
            catch { try? scheduler.requireInspection("cannot save cluster task completion: \(error)") }
        }
        return initial
    }
    private func reapClusterReservations() {
        lock.lock()
        let expired = clusterReservations.filter { $0.value.reservation.expiresAt < Date() }
        lock.unlock()
        for (id, value) in expired {
            lock.lock(); defer { lock.unlock() }
            guard clusterReservations[id]?.reservation.id == value.reservation.id else { continue }
            do { _ = try withdrawClusterTask(value.task.id, reservationID: id) }
            catch { try? scheduler.requireInspection("reserved Host cleanup failed: \(error)") }
        }
    }
    private func withdrawClusterTask(_ taskID: String, reservationID: String) throws -> ClusterTaskUpdate? {
        guard UUID(uuidString: taskID) != nil else { throw SandboxError("invalid cluster task ID") }
        lock.lock()
        if let job = clusterJobs[taskID] {
            guard job.update.reservationID == reservationID else { lock.unlock(); throw SandboxError("cluster task reservation differs") }
            var update = job.update
            if job.token.cancelBeforeExecution() {
                update.state = "withdrawing"; clusterJobs[taskID]?.update = update
            }
            else { update.state = "running" }
            lock.unlock(); return update
        }
        let reserved = clusterReservations[reservationID]
        guard reserved == nil || reserved?.task.id == taskID else { lock.unlock(); throw SandboxError("cluster reservation task differs") }
        let path = directory.appendingPathComponent("cluster_jobs/\(taskID).json")
        if reserved == nil, FileManager.default.fileExists(atPath: path.path) {
            defer { lock.unlock() }
            let update = try SafeFiles.read(ClusterTaskUpdate.self, from: path)
            guard update.reservationID == reservationID else { throw SandboxError("cluster task reservation differs") }
            return update.state == "withdrawn" && update.cleanupConfirmed == true ? nil : update
        }
        var update = ClusterTaskUpdate(taskID: taskID, state: "withdrawing")
        update.reservationID = reservationID
        do { try SafeFiles.write(update, to: path) }
        catch { lock.unlock(); throw error }
        clusterReservations.removeValue(forKey: reservationID)
        lock.unlock()
        if let reserved {
            do { try reserved.session.close(); _ = try factory.purge(reserved.session.id, logicalID: reserved.task.instanceID) }
            catch { try scheduler.requireInspection("reserved Host cleanup failed: \(error)"); throw error }
        }
        update.state = "withdrawn"; update.cleanupConfirmed = true
        try SafeFiles.write(update, to: path)
        scheduler.releaseReservation(reservationID)
        return nil
    }
    public func transfer(_ request: NativeControlRequest, channel: FramedChannel) throws {
        if request.localOnly != true, let clusterController {
            if request.handle == nil { try admin(request) }
            if try clusterController.transfer(request, channel: channel) { return }
        }
        var reply = NativeControlReply(requestID: request.requestID)
        var responseStarted = false
        do {
            if request.operation == "test-package" {
                try admin(request)
                try WorkspaceArchive.temporary(directory: directory.appendingPathComponent("test_packages")) { url in
                    responseStarted = true; try channel.send(reply)
                    let failure = try channel.receiveFile(to: url)
                    do {
                        if let failure { throw failure }
                        let hash = try TaskPackage.testsFingerprint(url)
                        let folder = directory.appendingPathComponent("test_packages/\(hash)")
                        try SafeFiles.secureDirectory(folder)
                        let target = folder.appendingPathComponent("tests.zip")
                        testPackageLock.lock(); defer { testPackageLock.unlock() }
                        if FileManager.default.fileExists(atPath: target.path) { _ = try testArchive(hash) }
                        else { try WorkspaceArchive.copy(url, to: target) }
                        reply.testPackageSHA256 = hash
                    } catch { reply.ok = false; reply.error = String(describing: error) }
                    try channel.send(reply)
                }
                return
            }
            if request.taskImport == true {
                try admin(request)
                if let hash = request.testPackageSHA256 { _ = try testArchive(hash) }
            }
            let operation: SandboxOperation = request.operation == "upload" ? .write : request.path == nil ? .export : .read
            try withFiles(request, operation: operation, checkpoint: false) { client in
                try WorkspaceArchive.temporary(directory: directory.appendingPathComponent("checkpoints")) { url in
                    if request.operation == "download" {
                        do {
                            if request.path == nil, let offline = client as? AppSandboxSession, let id = request.instanceID {
                                let received = try offline.downloadArchive(to: url, path: nil)
                                try checkpointStopped(id, session: offline, archive: (url, received.summary, received.sha256))
                            } else { try client.download(to: url, path: request.path) }
                        }
                        catch { reply.ok = false; reply.error = String(describing: error) }
                        responseStarted = true; try channel.send(reply)
                        if reply.ok { _ = try channel.sendFile(url) }
                    } else {
                        responseStarted = true; try channel.send(reply)
                        let failure = try channel.receiveFile(to: url)
                        do {
                            if let failure { throw failure }; try client.upload(from: url)
                            if request.taskImport == true, let id = request.instanceID {
                                try saveVerificationSettings(VerificationSettings(testPackageSHA256: request.testPackageSHA256,
                                    enabled: request.testPackageSHA256 != nil), id: id)
                            }
                        }
                        catch { reply.ok = false; reply.error = String(describing: error) }
                        try channel.send(reply)
                    }
                }
            }
        } catch {
            if responseStarted { throw error }
            reply.ok = false; reply.error = String(describing: error); try channel.send(reply)
        }
    }
    private func forwardingRequest(_ request: NativeControlRequest) throws -> NativeControlReply {
        var request = request; request.operatorToken = operatorToken
        if let reply = try clusterController?.handle(request) { return reply }
        request.localOnly = true
        let reply = handle(request)
        guard reply.ok else { throw SandboxError(reply.error ?? "forwarding metadata request failed") }
        return reply
    }
    private func forward(_ request: NativeControlRequest) throws -> NativeControlReply {
        try admin(request)
        guard let instanceID = request.instanceID, let id = request.forwardID, UUID(uuidString: id) != nil else {
            throw SandboxError("forwarding requires instance ID and a UUID lease ID")
        }
        try Self.validateID(instanceID)
        var reply = NativeControlReply(requestID: request.requestID)
        if request.operation == "port-forward-status" {
            reply.portForward = try loopbackForwards.status(id: id, instanceID: instanceID)
        } else if request.operation == "port-forward-close" {
            guard loopbackForwards.close(id: id, instanceID: instanceID) else { throw SandboxError("forwarding process cleanup is unconfirmed") }
            var detach = request; detach.operation = "port-forward-require"; detach.confirmed = false
            _ = try forwardingRequest(detach)
            reply.confirmed = true
        } else {
            lock.lock(); let available = accepting; lock.unlock()
            guard available, let port = request.forwardPort else { throw SandboxError("forwarding requires an available manager and source port") }
            try LoopbackPort.validate(port)
            var inspect = NativeControlRequest("inspect"); inspect.instanceID = instanceID
            guard let instance = try forwardingRequest(inspect).instance, instance.networkClient == true else {
                throw SandboxError("loopback forwarding requires a network-enabled instance")
            }
            var attach = request; attach.operation = "port-forward-require"; attach.confirmed = true
            _ = try forwardingRequest(attach)
            do {
                reply.portForward = try loopbackForwards.open(id: id, instanceID: instanceID,
                    owner: instance.nodeID ?? clusterConfiguration?.localNodeID ?? "local", port: port)
            } catch {
                guard loopbackForwards.close(id: id, instanceID: instanceID) else { throw SandboxError("forwarding setup failed and cleanup is unconfirmed") }
                attach.confirmed = false
                _ = try forwardingRequest(attach)
                throw error
            }
        }
        return reply
    }
    public func handle(_ request: NativeControlRequest) -> NativeControlReply {
        var reply = NativeControlReply(requestID: request.requestID)
        do {
            if ["port-forward-open", "port-forward-status", "port-forward-close"].contains(request.operation) {
                return try forward(request)
            }
            if request.localOnly != true, let clusterController {
                if request.handle == nil { try admin(request) }
                if let response = try clusterController.handle(request) {
                    if request.operation == "delete", response.ok, let id = request.instanceID,
                       !loopbackForwards.close(instanceID: id) { throw SandboxError("instance deleted; forwarding process cleanup is unconfirmed") }
                    return response
                }
            }
            switch request.operation {
            case "status":
                try admin(request); reply.status = status
                reply.status?.serialSlotAvailable = scheduler.serialSlotAvailable
                reply.status?.nodeID = clusterConfiguration?.localNodeID
                reply.status?.sharedRoot = clusterConfiguration?.sharedRoot
                if request.localOnly != true { reply.status?.clusterNodes = clusterController?.nodeStatuses }
            case "cluster": try admin(request); reply.cluster = clusterConfiguration
            case "port-forward-probe":
                try admin(request)
                guard let port = request.forwardPort else { throw SandboxError("missing loopback port") }
                try LoopbackPort.check(port); reply.confirmed = true
            case "port-forward-require":
                try admin(request)
                guard let id = request.instanceID, let forward = request.forwardID, UUID(uuidString: forward) != nil,
                      let enabled = request.confirmed else { throw SandboxError("invalid forwarding dependency") }
                try Self.validateID(id)
                creationLock.lock(); defer { creationLock.unlock() }
                lock.lock(); defer { lock.unlock() }
                if let entry = entries[id] {
                    try entry.session.requireLoopbackForward(forward, enabled: enabled)
                } else if var record = historical[id] {
                    var ids = Set(record.loopbackForwardIDs ?? [])
                    if enabled { ids.insert(forward) } else { ids.remove(forward) }
                    record.loopbackForwardIDs = ids.isEmpty ? nil : ids.sorted()
                    record.updatedAt = Date()
                    try SafeFiles.write(record, to: directory.appendingPathComponent("instances/\(id).json"))
                    historical[id] = record
                } else if enabled { throw SandboxError("unknown forwarding instance") }
                reply.confirmed = true
            case "cluster-pending":
                try admin(request)
                reply.clusterTasks = clusterConfiguration?.crossNodeSchedulingEnabled == false ? [] : clusterTasks.pending()
                lock.lock()
                reply.clusterTasks = reply.clusterTasks?.map { task in
                    var task = task
                    task.loopbackForwardIDs = (entries[task.instanceID]?.session.summary ?? historical[task.instanceID])?.loopbackForwardIDs
                    return task
                }
                lock.unlock()
            case "cluster-claim":
                try admin(request)
                guard let id = request.executionID else { throw SandboxError("missing cluster task ID") }
                reply.claimed = try clusterConfiguration?.crossNodeSchedulingEnabled != false && clusterTasks.claim(id)
            case "cluster-task-state":
                try admin(request)
                guard let id = request.executionID else { throw SandboxError("missing cluster task ID") }
                reply.claimed = clusterTasks.isClaimed(id)
                reply.clusterUpdate = ClusterTaskUpdate(taskID: id, state: clusterTasks.contains(id) ? "present" : "missing")
                reply.confirmed = clusterTasks.contains(id) ? try clusterTasks.cancelled(id) : true
            case "cluster-complete":
                try admin(request)
                guard let update = request.clusterUpdate else { throw SandboxError("missing cluster completion") }
                if update.cleanupConfirmed != true {
                    try scheduler.requireInspection(update.error ?? "remote process cleanup requires inspection")
                }
                if clusterTasks.contains(update.taskID) { try clusterTasks.complete(update) }
            case "cluster-started":
                try admin(request)
                guard let id = request.executionID else { throw SandboxError("missing cluster task ID") }
                if clusterTasks.contains(id) { try clusterTasks.started(id) }
            case "cluster-reserve":
                try admin(request)
                guard let task = request.clusterTask else { throw SandboxError("missing cluster task") }
                reply.clusterReservation = try reserveClusterTask(task)
            case "cluster-release":
                try admin(request)
                guard let id = request.reservationID else { throw SandboxError("missing reservation ID") }
                scheduler.releaseReservation(id)
                lock.lock(); let session = clusterReservations.removeValue(forKey: id); lock.unlock()
                if let session { try session.session.close(); _ = try factory.purge(session.session.id, logicalID: session.task.instanceID) }
            case "cluster-commit":
                try admin(request)
                guard let task = request.clusterTask, let reservation = request.reservationID else { throw SandboxError("missing cluster commit") }
                reply.clusterUpdate = try commitClusterTask(task, reservation: reservation)
            case "cluster-withdraw":
                try admin(request)
                guard let id = request.executionID, let reservation = request.reservationID else { throw SandboxError("missing cluster withdrawal identity") }
                reply.clusterUpdate = try withdrawClusterTask(id, reservationID: reservation)
                reply.confirmed = reply.clusterUpdate == nil
            case "cluster-result", "cluster-cancel":
                try admin(request)
                guard let id = request.executionID, UUID(uuidString: id) != nil else { throw SandboxError("invalid cluster task ID") }
                lock.lock()
                if request.operation == "cluster-cancel" { clusterJobs[id]?.token.cancel() }
                reply.clusterUpdate = clusterJobs[id]?.update
                lock.unlock()
                if reply.clusterUpdate == nil {
                    let url = directory.appendingPathComponent("cluster_jobs/\(id).json")
                    guard FileManager.default.fileExists(atPath: url.path) else { throw SandboxError("unknown cluster task", code: .clusterTaskUnknown) }
                    reply.clusterUpdate = try SafeFiles.read(ClusterTaskUpdate.self, from: url)
                }
            case "create":
                try admin(request)
                guard request.schedulingPool == nil else { throw SandboxError("scheduling pool selection requires a cluster configuration") }
                creationLock.lock(); defer { creationLock.unlock() }
                let count = request.count ?? 1
                guard count > 0, count <= 16 else { throw SandboxError("count must be 1...16") }
                try requireInstanceSlots(count, limit: request.instanceLimit)
                try request.taskPolicy?.validate()
                try EnvironmentVariables.validate(request.environment ?? [:])
                let names = try NativeInstanceRecord.replicaNames(request.name, count: count)
                var created: [NativeInstanceRecord] = []
                do { for name in names { created.append(try create(networkClient: request.networkClient ?? true, taskPolicy: request.taskPolicy, environment: request.environment ?? [:], name: name, dynamicScheduling: request.dynamicScheduling == true, instanceLimit: request.instanceLimit)) } }
                catch {
                    for record in created {
                        var cleanup = NativeControlRequest("stop"); cleanup.operatorToken = operatorToken; cleanup.instanceID = record.id
                        _ = try? stop(cleanup)
                    }
                    throw error
                }
                reply.instances = created
            case "rename":
                try admin(request)
                guard let id = request.instanceID, let rawName = request.name else { throw SandboxError("rename requires ID and name; use an empty name to clear") }
                try Self.validateID(id)
                let name = try NativeInstanceRecord.normalizedName(rawName)
                creationLock.lock(); defer { creationLock.unlock() }
                lock.lock(); defer { lock.unlock() }
                if let entry = entries[id] {
                    try entry.session.rename(name); reply.instance = entry.session.summary
                } else if var record = historical[id] {
                    record.name = name; record.updatedAt = Date()
                    try SafeFiles.write(record, to: directory.appendingPathComponent("instances/\(id).json"))
                    historical[id] = record; reply.instance = record
                } else { throw SandboxError("unknown instance") }
            case "list":
                try admin(request); lock.lock()
                reply.instances = (Array(historical.values) + entries.values.map { $0.session.summary }).sorted { $0.createdAt < $1.createdAt }
                lock.unlock()
            case "inspect":
                if isOperator(request), let id = request.instanceID {
                    lock.lock(); reply.instance = entries[id]?.session.summary ?? historical[id]; lock.unlock()
                    guard reply.instance != nil else { throw SandboxError("unknown instance") }
                } else { reply.instance = try access(request, .read).0.session.summary }
            case "environment":
                try admin(request)
                guard let id = request.instanceID else { throw SandboxError("missing instanceID") }
                try Self.validateID(id)
                creationLock.lock(); defer { creationLock.unlock() }
                lock.lock(); let exists = entries[id] != nil || historical[id] != nil; lock.unlock()
                guard exists else { throw SandboxError("unknown instance") }
                if let values = request.environment {
                    try EnvironmentVariables.validate(values)
                    try SafeFiles.write(values, to: environmentURL(id))
                }
                let values = try loadEnvironment(id)
                reply.environmentKeys = values.keys.sorted()
                if request.environment == nil && request.revealEnvironment == true { reply.environment = values }
            case "grant":
                try admin(request)
                let (entry, _) = try access(request, .stop)
                reply.handle = try registry.grant(entry.owner, operations: request.operations ?? [.read, .write, .export, .exec])
            case "trajectory":
                reply.trajectory = try withFiles(request, operation: .read) { try $0.trajectory(session: request.path, after: request.after) }
            case "workspace-location":
                try admin(request)
                reply.workspaceLocation = try withFiles(request, operation: .read) { try $0.workspaceLocation(request.path ?? ".") }
            case "ls":
                reply.directory = try withFiles(request, operation: .read) { try $0.listDirectory(request.path ?? ".", after: request.after) }
            case "read":
                guard let path = request.path else { throw SandboxError("missing path") }
                reply.file = try withFiles(request, operation: .read) { try $0.read(path) }
            case "write":
                guard let file = request.file else { throw SandboxError("missing file") }
                try withFiles(request, operation: .write) { try $0.write(file) }
            case "snapshot":
                try withFiles(request, operation: .export, checkpoint: false) { client in
                    if let offline = client as? AppSandboxSession, let id = request.instanceID {
                        try checkpointStopped(id, session: offline)
                    } else {
                        try WorkspaceArchive.temporary(directory: directory.appendingPathComponent("checkpoints")) { archive in
                            try client.download(to: archive, path: nil)
                        }
                    }
                }
                if let id = request.instanceID {
                    lock.lock(); reply.instance = entries[id]?.session.summary ?? historical[id]; lock.unlock()
                }
            case "export": reply.files = try withFiles(request, operation: .export) { try $0.export() }
            case "exec": reply.execution = try submit(request)
            case "verification-settings":
                try admin(request)
                guard let id = request.instanceID else { throw SandboxError("missing instanceID") }
                try Self.validateID(id)
                let gate = fileGate(id); gate.lock(); defer { gate.unlock() }
                lock.lock(); let exists = entries[id] != nil || historical[id] != nil; lock.unlock()
                guard exists else { throw SandboxError("unknown instance") }
                if var settings = request.verificationSettings {
                    settings.testPackageSHA256 = try verificationSettings(id).testPackageSHA256
                    try saveVerificationSettings(settings, id: id)
                }
                reply.verificationSettings = try verificationSettings(id)
            case "verify":
                try admin(request)
                if let id = request.executionID { reply.execution = try attachVerification(request, executionID: id) }
                else { reply.execution = try submitVerification(request) }
            case "execution": reply.execution = try executionAccess(request)
            case "executions":
                try admin(request)
                let count = request.count ?? 100
                guard count > 0 && count <= 200 else { throw SandboxError("history limit must be 1...200") }
                if let id = request.instanceID { try Self.validateID(id) }
                lock.lock(); defer { lock.unlock() }
                var all = executionHistory.values.filter { request.instanceID == nil || $0.instanceID == request.instanceID }
                    .sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
                reply.pendingExecutions = all.filter { ["queued", "running"].contains($0.state) }
                if let cursor = request.after {
                    guard let index = all.firstIndex(where: { $0.id == cursor }) else { throw SandboxError("unknown execution history cursor") }
                    all = Array(all.dropFirst(index + 1))
                }
                reply.executions = Array(all.prefix(count))
                reply.nextExecutionCursor = all.count > count ? reply.executions?.last?.id : nil
            case "cancel":
                let record = try executionAccess(request)
                let gate = fileGate(record.instanceID); gate.lock(); defer { gate.unlock() }
                lock.lock(); defer { lock.unlock() }
                try cancelAutomaticVerification(record.id)
                cancellation[record.id]?.cancel(); reply.execution = try self.record(record.id)
            case "stop": reply.instance = try stop(request)
            case "start": reply.instance = try start(request)
            case "cleanup-deleted", "cleanup-unclaimed": reply.cleanup = try cleanup(request)
            case "delete":
                reply.instance = try delete(request)
                if let id = request.instanceID, !loopbackForwards.close(instanceID: id) {
                    throw SandboxError("instance deleted; forwarding process cleanup is unconfirmed")
                }
                reply.warnings = reply.instance?.cleanupWarnings ?? []
            case "restore":
                try admin(request)
                creationLock.lock(); defer { creationLock.unlock() }
                guard let id = request.instanceID else { throw SandboxError("missing source instance") }
                try Self.validateID(id)
                let gate = fileGate(id); gate.lock(); defer { gate.unlock() }
                lock.lock(); let source = historical[id]; lock.unlock()
                guard let source, source.canRestore else { throw SandboxError("restore requires a stopped/interrupted instance with a valid checkpoint") }
                reply.instance = try WorkspaceCheckpoint.withArchive(directory: directory, id: id, sha256: source.checkpointSHA256) { archive in
                    try create(seedArchive: archive, networkClient: source.networkClient == true, taskPolicy: source.taskPolicy,
                        environment: loadEnvironment(id), dynamicScheduling: source.dynamicScheduling == true, instanceLimit: request.instanceLimit)
                }
            case "recover":
                try admin(request)
                lock.lock()
                let live = entries.values.map(\.session)
                let connected = live.allSatisfy { $0.summary.state == .active }
                let clusterIdle = clusterJobs.values.allSatisfy { $0.update.state == "queued" }
                lock.unlock()
                guard connected, clusterIdle else { throw SandboxError("stop disconnected instances and finish running remote commands before node recovery") }
                try scheduler.acknowledgeRecovery(confirmed: request.confirmed == true, note: request.note ?? "") {
                    for session in live { try session.acknowledgeRecovery() }
                    try clusterTasks.archiveClaims(to: directory.appendingPathComponent("cluster_claims_recovery/" + UUID().uuidString.lowercased()))
                }
                reply.status = status
            case "shutdown":
                try admin(request)
                if request.onlyIfIdle == true { try beginIdleShutdown() }
                else { beginShutdown() }
            default: throw SandboxError("unknown native operation")
            }
        } catch { reply.ok = false; reply.error = String(describing: error); reply.errorCode = (error as? SandboxError)?.code }
        if reply.instance != nil || reply.instances != nil {
            lock.lock()
            let counts = scheduler.counts.byOwner
            func executionCounts(_ record: NativeInstanceRecord) -> ExecutionCounts {
                counts[record.id, default: ExecutionCounts()] + (record.physical.flatMap { counts[$0.bundleID] } ?? ExecutionCounts())
            }
            if var record = reply.instance {
                record.nodeID = clusterConfiguration?.localNodeID
                record.executionCounts = executionCounts(record)
                record.pendingExecutions = record.executionCounts?.total
                record.availableActions = record.actions(isLive: entries[record.id] != nil)
                reply.instance = record
            }
            reply.instances = reply.instances?.map { record in
                var record = record; record.executionCounts = executionCounts(record)
                record.nodeID = clusterConfiguration?.localNodeID
                record.pendingExecutions = record.executionCounts?.total
                record.availableActions = record.actions(isLive: entries[record.id] != nil); return record
            }
            lock.unlock()
        }
        return reply
    }
    public func beginShutdown() {
        lock.lock(); accepting = false; cancellation.values.forEach { $0.cancel() }; clusterJobs.values.forEach { $0.token.cancel() }; lock.unlock()
    }
    private func beginIdleShutdown() throws {
        creationLock.lock(); defer { creationLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        guard entries.isEmpty, cancellation.isEmpty, clusterJobs.isEmpty, clusterReservations.isEmpty,
              scheduler.counts.total.total == 0 else {
            throw SandboxError("cannot apply service settings while local instances or commands are active")
        }
        accepting = false
    }
    public func shutdown() {
        verificationTimer?.cancel(); verificationQueue.sync {}; verificationTimer = nil
        fileReaper?.cancel(); fileReaperQueue.sync {}; fileReaper = nil
        beginShutdown(); work.wait()
        clusterController?.close(); clusterController = nil
        loopbackForwards.shutdown()
        lock.lock(); let reserved = clusterReservations; clusterReservations = [:]; lock.unlock()
        for (id, value) in reserved { scheduler.releaseReservation(id); try? value.session.close() }
        creationLock.lock(); defer { creationLock.unlock() }
        lock.lock(); let ids = Array(entries.keys); lock.unlock()
        for id in ids {
            var request = NativeControlRequest("stop"); request.operatorToken = operatorToken; request.instanceID = id
            do { _ = try stop(request, cancelFollowingVerification: false) }
            catch { FileHandle.standardError.write(Data("native cleanup: \(error)\n".utf8)) }
        }
        lock.lock(); let workerIDs = Array(fileWorkers.keys); lock.unlock()
        for id in workerIDs {
            let gate = fileGate(id); gate.lock(); defer { gate.unlock() }
            do { try closeFileWorker(id) } catch { FileHandle.standardError.write(Data("file worker cleanup: \(error)\n".utf8)) }
        }
        withExtendedLifetime(stateLease) {}
    }
}
