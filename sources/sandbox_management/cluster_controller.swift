import Foundation
import SandboxCore
import SandboxRuntime

public final class ClusterController {
    private struct Migration: Codable {
        var task: ClusterTask
        var source: String
        var target: String
        var reservation: String
        var phase: String
    }
    public let configuration: ClusterConfiguration
    var loopbackForwards: LoopbackForwardRegistry?
    private let transport: ClusterTransport
    private let local: (NativeControlRequest) -> NativeControlReply
    private let directory: URL
    private let lock = NSRecursiveLock()
    private let placement = ClusterPlacement()
    private let creationLock = NSLock()
    private var routes: [String: String] = [:]
    private var executionRoutes: [String: String] = [:]
    private var nodeInstances: [String: [NativeInstanceRecord]] = [:]
    private var migrations: [String: Migration] = [:]
    private var samples: [ClusterNodeStatus] = []
    private let queue = DispatchQueue(label: "metal-sandbox.cluster")
    private var timer: DispatchSourceTimer?
    public init(configuration: ClusterConfiguration, directory: URL, transport: ClusterTransport,
                local: @escaping (NativeControlRequest) -> NativeControlReply) throws {
        try configuration.validate(); self.configuration = configuration; self.transport = transport; self.local = local
        self.directory = directory.appendingPathComponent("cluster")
        try SafeFiles.secureDirectory(self.directory)
        let routesURL = self.directory.appendingPathComponent("instances.json")
        if FileManager.default.fileExists(atPath: routesURL.path) { routes = try SafeFiles.read([String: String].self, from: routesURL) }
        let path = self.directory.appendingPathComponent("migrations.json")
        if FileManager.default.fileExists(atPath: path.path) { migrations = try SafeFiles.read([String: Migration].self, from: path) }
        let instances = self.directory.appendingPathComponent("node_instances.json")
        if FileManager.default.fileExists(atPath: instances.path) { nodeInstances = try SafeFiles.read([String: [NativeInstanceRecord]].self, from: instances) }
        try SafeFiles.write(executionRoutes, to: self.directory.appendingPathComponent("executions.json"))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
    }
    static let retryableOperations: Set<String> = ["status", "list", "inspect", "execution", "executions",
                                                   "trajectory", "ls", "read", "workspace-location"]
    private func request(_ request: NativeControlRequest, node id: String, retry: Bool = true) throws -> NativeControlReply {
        var value = request; value.localOnly = true
        let reply: NativeControlReply
        if id == configuration.localNodeID { reply = local(value) }
        else {
            guard let node = configuration.nodes.first(where: { $0.id == id }) else { throw SandboxError("unknown cluster node: \(id)") }
            reply = try relay(value, node: node, retry: retry && Self.retryableOperations.contains(value.operation))
        }
        guard reply.ok else { throw SandboxError(reply.error ?? "cluster request rejected", code: reply.errorCode) }
        return reply
    }
    // Only read-only queries are repeated: the control protocol has no request deduplication.
    private func relay(_ request: NativeControlRequest, node: ClusterNode, retry: Bool) throws -> NativeControlReply {
        var attempt = 0
        while true {
            do { return try transport.request(request, node: node) }
            catch {
                guard retry, attempt < 10 else { throw error }
                Thread.sleep(forTimeInterval: 0.5 * Double(1 << attempt)); attempt += 1
            }
        }
    }
    public func node(for request: NativeControlRequest) -> ClusterNode? {
        lock.lock(); defer { lock.unlock() }
        let id = request.instanceID.flatMap { routes[$0] } ?? request.executionID.flatMap { executionRoutes[$0] }
        return configuration.nodes.first { $0.id == id }
    }
    private func remember(_ reply: NativeControlReply, node: String) throws {
        lock.lock(); defer { lock.unlock() }
        let before = routes, priorExecutions = executionRoutes
        for record in (reply.instances ?? []) + [reply.instance].compactMap({ $0 }) { routes[record.id] = node }
        if let execution = reply.execution { executionRoutes[execution.id] = node }
        for execution in reply.executions ?? [] { executionRoutes[execution.id] = node }
        if routes != before { try SafeFiles.write(routes, to: directory.appendingPathComponent("instances.json")) }
        if executionRoutes != priorExecutions { try SafeFiles.write(executionRoutes, to: directory.appendingPathComponent("executions.json")) }
    }
    private func rememberInstances(_ instances: [NativeInstanceRecord], node: String) throws {
        lock.lock(); defer { lock.unlock() }
        nodeInstances[node] = instances
        try SafeFiles.write(nodeInstances, to: directory.appendingPathComponent("node_instances.json"))
    }
    public func refresh() -> [ClusterNodeStatus] {
        let ids = [configuration.localNodeID] + configuration.nodes.map(\.id)
        let group = DispatchGroup(), resultsLock = NSLock()
        var results: [ClusterNodeStatus] = []
        for id in ids {
            group.enter()
            DispatchQueue.global().async { [self] in
                defer { group.leave() }
                let result: ClusterNodeStatus
                do {
                    var status = try request(NativeControlRequest("status"), node: id, retry: false).status
                    let configured = id == configuration.localNodeID ? configuration.maxConcurrentInstances : configuration.nodes.first { $0.id == id }?.maxConcurrentInstances
                    if let configured {
                        let advertised = status?.maxConcurrentInstances ?? 32
                        status?.maxConcurrentInstances = min(advertised, configured)
                    }
                    result = ClusterNodeStatus(id: id, status: status)
                }
                catch { result = ClusterNodeStatus(id: id, error: String(describing: error)) }
                resultsLock.lock(); results.append(result); resultsLock.unlock()
            }
        }
        group.wait()
        lock.lock()
        samples = results.map { result in
            var result = result
            result.schedulingPool = configuration.pool(for: result.id)
            result.crossNodeSchedulingEnabled = configuration.permitsCrossNodeScheduling(result.id)
            if result.status == nil {
                let previous = samples.first { $0.id == result.id }
                result.lastKnownStatus = previous?.status ?? previous?.lastKnownStatus
            }
            return result
        }.sorted { $0.id < $1.id }
        let snapshot = samples
        lock.unlock()
        return snapshot
    }
    public var nodeStatuses: [ClusterNodeStatus] { lock.lock(); defer { lock.unlock() }; return samples }
    public func handle(_ input: NativeControlRequest) throws -> NativeControlReply? {
        if input.handle != nil {
            guard let node = node(for: input) else { return nil }
            return try request(input, node: node.id)
        }
        if input.operation == "cluster" {
            var reply = NativeControlReply(requestID: input.requestID); reply.cluster = configuration; return reply
        }
        if input.operation == "status" {
            var reply = try request(input, node: configuration.localNodeID)
            let nodes = nodeStatuses
            if !nodes.isEmpty {
                reply.status?.activeInstances = nodes.compactMap(\.status).reduce(0) { $0 + $1.activeInstances }
                let counts = nodes.compactMap(\.status).reduce(ExecutionCounts()) { $0 + $1.executionCounts }
                reply.status?.executionCounts = counts
                reply.status?.pendingExecutions = counts.total
                reply.status?.executionSlots = nodes.filter { $0.status != nil }.count
            }
            reply.status?.nodeID = configuration.localNodeID; reply.status?.clusterNodes = nodes
            return reply
        }
        if input.operation == "create" {
            creationLock.lock(); defer { creationLock.unlock() }
            if let pool = input.schedulingPool {
                try ClusterConfiguration.validatePool(pool)
                let ids = [configuration.localNodeID] + configuration.nodes.map(\.id)
                guard ids.contains(where: { configuration.pool(for: $0) == pool }) else { throw SandboxError("unknown scheduling pool: \(pool)") }
                if let id = input.nodeID, configuration.pool(for: id) != pool { throw SandboxError("selected node does not belong to the scheduling pool") }
            }
            let count = input.count ?? 1
            guard count > 0, count <= 16 else { throw SandboxError("count must be 1...16") }
            let names = try NativeInstanceRecord.replicaNames(input.name, count: count)
            var nodes = refresh(), reply = NativeControlReply(requestID: input.requestID)
            if let pool = input.schedulingPool { nodes = nodes.filter { $0.pool == pool } }
            let eligible = nodes.filter { $0.readyForExecution && $0.instanceLimit > 0 && (input.nodeID == nil || $0.id == input.nodeID) }
            var needed = count
            for node in eligible { needed -= min(needed, max(0, node.instanceLimit - node.status!.activeInstances)) }
            if !eligible.isEmpty, needed > 0 { throw SandboxError("cluster active-instance capacity is full", code: .instanceCapacityUnavailable) }
            reply.instances = []
            do {
                for name in names {
                    let id = try placement.reserve(nodes: nodes, preferred: input.nodeID)
                    defer { placement.release(id) }
                    var request = input; request.count = 1; request.name = name
                    request.schedulingPool = nil
                    request.instanceLimit = nodes.first { $0.id == id }!.instanceLimit
                    let created = try self.request(request, node: id)
                    try remember(created, node: id)
                    reply.instances! += (created.instances ?? []).map { var value = $0; value.nodeID = id; return value }
                    if let index = nodes.firstIndex(where: { $0.id == id }), var status = nodes[index].status {
                        status.activeInstances += 1; nodes[index].status = status
                    }
                }
            } catch {
                for instance in reply.instances ?? [] {
                    var stop = NativeControlRequest("stop"); stop.instanceID = instance.id
                    do { _ = try request(stop, node: instance.nodeID!) }
                    catch { FileHandle.standardError.write(Data("cluster batch cleanup: \(error)\n".utf8)) }
                }
                throw error
            }
            return reply
        }
        if ["start", "restore"].contains(input.operation), let instanceID = input.instanceID {
            creationLock.lock(); defer { creationLock.unlock() }
            lock.lock(); let owner = routes[instanceID] ?? configuration.localNodeID; lock.unlock()
            var request = input
            request.instanceLimit = owner == configuration.localNodeID ? configuration.maxConcurrentInstances : configuration.nodes.first { $0.id == owner }?.maxConcurrentInstances
            var reply = try self.request(request, node: owner)
            try remember(reply, node: owner)
            reply.instance?.nodeID = owner
            return reply
        }
        if ["list", "executions"].contains(input.operation), input.instanceID == nil {
            var reply = NativeControlReply(requestID: input.requestID)
            var records: [NativeInstanceRecord] = [], history: [NativeExecutionBrief] = [], pending: [NativeExecutionBrief] = []
            for id in [configuration.localNodeID] + configuration.nodes.map(\.id) {
                var query = input
                if input.operation == "executions" { query.after = nil; query.count = 200 }
                let value: NativeControlReply
                do { value = try request(query, node: id) }
                catch {
                    if input.operation != "list" { throw error }
                    reply.warnings = (reply.warnings ?? []) + ["\(id): \(error)"]
                    lock.lock(); let cached = nodeInstances[id] ?? []; lock.unlock()
                    records += cached.map {
                        var record = $0; record.nodeID = id; record.state = .interrupted
                        record.availableActions = []; record.error = "node disconnected: \(error)"
                        return record
                    }
                    continue
                }
                try remember(value, node: id)
                if input.operation == "list" { try rememberInstances(value.instances ?? [], node: id) }
                records += (value.instances ?? []).map { var value = $0; value.nodeID = id; return value }
                history += value.executions ?? []; pending += value.pendingExecutions ?? []
                if input.operation == "executions", let cursor = input.after {
                    var next = value.nextExecutionCursor
                    var seen = value.executions?.contains { $0.id == cursor } ?? false
                    while let after = next, !seen {
                        query.after = after
                        let older = try request(query, node: id)
                        try remember(older, node: id)
                        history += older.executions ?? []
                        seen = older.executions?.contains { $0.id == cursor } ?? false
                        next = older.nextExecutionCursor
                    }
                    // Each node contributes at least the requested page below the global cursor.
                    if seen, let after = next {
                        query.after = after
                        let older = try request(query, node: id)
                        try remember(older, node: id); history += older.executions ?? []
                    }
                }
            }
            if input.operation == "list" { reply.instances = records.sorted { $0.createdAt < $1.createdAt } }
            else {
                let ordered = history.sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
                let offset: Int
                if let after = input.after {
                    guard let index = ordered.firstIndex(where: { $0.id == after }) else { throw SandboxError("cluster history cursor outside available page") }
                    offset = index + 1
                } else { offset = 0 }
                let page = ordered.dropFirst(offset), count = input.count ?? 100
                reply.executions = Array(page.prefix(count)); reply.pendingExecutions = pending
                reply.nextExecutionCursor = page.count > count ? reply.executions?.last?.id : nil
            }
            return reply
        }
        if let node = node(for: input) {
            var reply = try request(input, node: node.id)
            if input.handle == nil { try remember(reply, node: node.id) }
            reply.instance?.nodeID = node.id; return reply
        }
        return nil
    }
    public func transfer(_ input: NativeControlRequest, channel: FramedChannel) throws -> Bool {
        guard let node = node(for: input) else { return false }
        try transport.transfer(input, node: node, channel: channel); return true
    }
    private func rememberMigration(_ migration: Migration) throws {
        lock.lock(); defer { lock.unlock() }
        var next = migrations; next[migration.task.id] = migration
        try SafeFiles.write(next, to: directory.appendingPathComponent("migrations.json")); migrations = next
    }
    private func finishMigration(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var next = migrations; next.removeValue(forKey: id)
        try SafeFiles.write(next, to: directory.appendingPathComponent("migrations.json")); migrations = next
    }
    private func advance(_ migration: inout Migration) throws -> Bool {
        var request = NativeControlRequest("cluster-task-state"); request.executionID = migration.task.id
        if migration.phase == "claiming" {
            request.operation = "cluster-claim"
            let claimed = try self.request(request, node: migration.source).claimed == true
            if !claimed {
                request.operation = "cluster-task-state"
                if try self.request(request, node: migration.source).claimed != true {
                    request.operation = "cluster-release"; request.reservationID = migration.reservation
                    _ = try self.request(request, node: migration.target); return true
                }
            }
            migration.phase = "committing"
            try rememberMigration(migration)
        }
        if ["committing", "dispatching"].contains(migration.phase),
           (!configuration.permitsDispatch(from: migration.source, to: migration.target)
            || migration.task.schedulingPool != configuration.pool(for: migration.source)
            || !forwardingReady(migration.task, node: migration.target)) {
            migration.phase = "reselecting"
            try rememberMigration(migration)
        }
        if migration.phase == "committing" {
            request.operation = "cluster-task-state"
            let source = try self.request(request, node: migration.source)
            if source.clusterUpdate?.state == "missing" {
                var cleanup = NativeControlRequest("cluster-withdraw")
                cleanup.executionID = migration.task.id; cleanup.reservationID = migration.reservation
                let existing = try self.request(cleanup, node: migration.target)
                if existing.confirmed == true { return true }
                if existing.clusterUpdate?.state == "running" {
                    cleanup.operation = "cluster-cancel"
                    let result = try self.request(cleanup, node: migration.target).clusterUpdate
                    return result.map { ["finished", "failed"].contains($0.state) } ?? false
                }
                return existing.clusterUpdate.map { ["finished", "failed"].contains($0.state) } ?? false
            }
            request.operation = "cluster-commit"; request.reservationID = migration.reservation; request.clusterTask = migration.task
            do { _ = try self.request(request, node: migration.target) }
            catch let error as SandboxError where error.code == .clusterReservationExpired {
                migration.phase = "reselecting"
                try rememberMigration(migration)
            }
            catch {
                migration.phase = "reselecting"
                try rememberMigration(migration)
                throw error
            }
            if migration.phase == "committing" {
                migration.phase = "dispatching"
                try rememberMigration(migration)
            }
        }
        if migration.phase == "dispatching" {
            request.operation = "cluster-result"
            guard let result = try self.request(request, node: migration.target).clusterUpdate else { throw SandboxError("missing remote dispatch state") }
            guard result.reservationID == migration.reservation else { throw SandboxError("remote dispatch reservation differs") }
            if ["running", "finished", "failed"].contains(result.state) { migration.phase = "running" }
            else {
                guard ["queued", "withdrawing", "withdrawn"].contains(result.state) else { throw SandboxError("invalid remote dispatch state: \(result.state)") }
                request.operation = "cluster-task-state"
                let cancelled = try self.request(request, node: migration.source).confirmed == true
                let target = ClusterPlacement.pendingTarget(nodes: refresh(), source: migration.source)
                if !cancelled && result.state == "queued" && (target == nil || target == migration.target) { return false }
                migration.phase = "reselecting"
            }
            try rememberMigration(migration)
        }
        if migration.phase == "reselecting" {
            var withdraw = NativeControlRequest("cluster-withdraw")
            withdraw.executionID = migration.task.id; withdraw.reservationID = migration.reservation
            let reply = try self.request(withdraw, node: migration.target)
            if let result = reply.clusterUpdate {
                guard result.reservationID == migration.reservation else { throw SandboxError("remote withdrawal reservation differs") }
                if ["queued", "withdrawing"].contains(result.state) { return false }
                guard ["running", "finished", "failed"].contains(result.state) else { throw SandboxError("invalid remote withdrawal state: \(result.state)") }
                migration.phase = "running"
            }
            else {
                guard reply.confirmed == true else { throw SandboxError("cluster withdrawal was not confirmed") }
                migration.phase = "selecting"
            }
            try rememberMigration(migration)
        }
        if migration.phase == "selecting" {
            request.operation = "cluster-task-state"
            let source = try self.request(request, node: migration.source)
            if source.clusterUpdate?.state == "missing" { return true }
            if source.confirmed == true {
                var result = ClusterTaskUpdate(taskID: migration.task.id, state: "failed", error: "cancelled before grant; no process launched")
                result.cleanupConfirmed = true
                request.operation = "cluster-complete"; request.clusterUpdate = result
                _ = try self.request(request, node: migration.source)
                return true
            }
            let nodes = refresh().filter { $0.readyForExecution && forwardingReady(migration.task, node: $0.id) }
            guard let target = ClusterPlacement.pendingTarget(nodes: nodes, source: migration.source) else { return false }
            guard configuration.permitsDispatch(from: migration.source, to: target) else { throw SandboxError("cross-node scheduling policy rejected the target") }
            migration.task.schedulingPool = configuration.pool(for: migration.source)
            var reserve = NativeControlRequest("cluster-reserve"); reserve.clusterTask = migration.task
            guard let reservation = try self.request(reserve, node: target).clusterReservation else { return false }
            migration.target = target; migration.reservation = reservation.id; migration.phase = "committing"
            try rememberMigration(migration)
            return false
        }
        request.operation = "cluster-task-state"
        let cancelled = try self.request(request, node: migration.source).confirmed == true
        request.operation = cancelled ? "cluster-cancel" : "cluster-result"
        guard let result = try self.request(request, node: migration.target).clusterUpdate else { throw SandboxError("missing remote result") }
        if result.state == "running" || result.state == "finished" {
            request.operation = "cluster-started"
            _ = try self.request(request, node: migration.source)
        }
        if ["finished", "failed"].contains(result.state) {
            request.operation = "cluster-complete"; request.clusterUpdate = result
            _ = try self.request(request, node: migration.source); return true
        }
        return false
    }
    private func tick() {
        let nodes = refresh()
        lock.lock(); let active = Array(migrations.values); lock.unlock()
        for var migration in active {
            do {
                if try advance(&migration) {
                    try finishMigration(migration.task.id)
                }
            } catch { FileHandle.standardError.write(Data("cluster task \(migration.task.id): \(error)\n".utf8)) }
        }
        for source in nodes where source.readyForExecution {
            guard let target = ClusterPlacement.serialTarget(nodes: nodes, source: source.id) else { continue }
            guard configuration.permitsDispatch(from: source.id, to: target) else { continue }
            do {
                for var task in try request(NativeControlRequest("cluster-pending"), node: source.id).clusterTasks ?? [] {
                    lock.lock(); let exists = migrations[task.id] != nil; lock.unlock()
                    if exists { continue }
                    let candidates = nodes.filter { $0.readyForExecution && forwardingReady(task, node: $0.id) }
                    guard let target = ClusterPlacement.serialTarget(nodes: candidates, source: source.id) else { continue }
                    task.schedulingPool = source.pool
                    var reserve = NativeControlRequest("cluster-reserve"); reserve.clusterTask = task
                    guard let reservation = try request(reserve, node: target).clusterReservation else { break }
                    var migration = Migration(task: task, source: source.id, target: target, reservation: reservation.id, phase: "claiming")
                    try rememberMigration(migration)
                    if try advance(&migration) {
                        try finishMigration(task.id)
                    }
                    break
                }
            } catch { FileHandle.standardError.write(Data("cluster scheduling: \(error)\n".utf8)) }
        }
    }
    private func forwardingReady(_ task: ClusterTask, node: String) -> Bool {
        guard let ids = task.loopbackForwardIDs, !ids.isEmpty else { return true }
        return loopbackForwards?.prepare(instanceID: task.instanceID, ids: ids, nodeID: node) == true
    }
    public func close() { timer?.cancel(); queue.sync {}; timer = nil }
    deinit { timer?.cancel() }
}
