import Foundation
import Darwin
import SandboxCore
import SandboxRuntime
import SandboxManagement

/// Uses a real public CLI relay process to the second manager on this Mac.
private final class LocalRelayTransport: ClusterTransport {
    let bin: URL
    let environment: [String: String]
    var beforeRequest: ((NativeControlRequest) -> Void)?
    var afterReply: ((NativeControlRequest, NativeControlReply) -> Void)?
    init(bin: URL, environment: [String: String]) { self.bin = bin; self.environment = environment }
    private func argv(_ node: ClusterNode) -> [String] { [bin.appendingPathComponent("sandboxctl").path, "--state-dir", node.stateDirectory, "cluster-relay"] }
    func request(_ input: NativeControlRequest, node: ClusterNode) throws -> NativeControlReply {
        beforeRequest?(input)
        let reply = try ClusterRelayConnection.withConnection(argv: argv(node), environment: environment) { try $0.request(input) }
        afterReply?(input, reply)
        return reply
    }
    func transfer(_ request: NativeControlRequest, node: ClusterNode, channel: FramedChannel) throws {
        try ClusterRelayConnection.withConnection(argv: argv(node), environment: environment) { try $0.transfer(request, peer: channel) }
    }
}

func runClusterIndexTests(bin: URL, output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SandboxError("index output must be new") }
    try SafeFiles.secureDirectory(output)
    let coordination = output.appendingPathComponent("relay")
    try SafeFiles.secureDirectory(coordination)
    let previous = ProcessInfo.processInfo.environment["METAL_SANDBOX_COORDINATION_DIR"]
    setenv("METAL_SANDBOX_COORDINATION_DIR", coordination.path, 1)
    defer { if let previous { setenv("METAL_SANDBOX_COORDINATION_DIR", previous, 1) } else { unsetenv("METAL_SANDBOX_COORDINATION_DIR") } }
    let workerState = output.appendingPathComponent("worker")
    let worker = try NativeManager(directory: workerState, binDirectory: bin, coordinationDirectory: output.appendingPathComponent("worker_coord"))
    defer { worker.shutdown() }
    let workerToken = try NativeControlClient.operatorToken(stateDirectory: workerState)
    let listeners = DispatchGroup()
    func listen() throws -> NativeControlServer {
        let server = NativeControlServer(transfer: worker.transfer) { worker.handle($0) }
        let ready = DispatchSemaphore(value: 0)
        listeners.enter()
        DispatchQueue.global().async {
            defer { listeners.leave() }
            do { try server.serve { ready.signal() } }
            catch { FileHandle.standardError.write(Data("index listener: \(error)\n".utf8)) }
        }
        guard ready.wait(timeout: .now() + 5) == .success else { throw SandboxError("index listener did not start") }
        return server
    }
    var server = try listen()
    defer { server.requestStop(); listeners.wait() }
    let node = ClusterNode(id: "worker", sshDestination: "unused", cliPath: bin.appendingPathComponent("sandboxctl").path, stateDirectory: workerState.path)
    let transport = LocalRelayTransport(bin: bin, environment: ProcessInfo.processInfo.environment)
    let config = output.appendingPathComponent("cluster_config.json")
    try SafeFiles.write(ClusterConfiguration(localNodeID: "manager", nodes: [node]), to: config)
    let state = output.appendingPathComponent("manager")
    func manager() throws -> NativeManager {
        try NativeManager(directory: state, binDirectory: bin, clusterURL: config, clusterTransport: transport,
            coordinationDirectory: output.appendingPathComponent("manager_coord"))
    }
    var control: NativeManager? = try manager()
    defer { control?.shutdown() }
    var token = try NativeControlClient.operatorToken(stateDirectory: state)
    func checked(_ input: NativeControlRequest) throws -> NativeControlReply {
        var request = input; request.operatorToken = token
        let reply = try unwrap(control).handle(request)
        guard reply.ok else { throw SandboxError(reply.error ?? "index request failed") }
        return reply
    }
    var create = NativeControlRequest("create"); create.nodeID = "worker"; create.count = 1
    let instance = try unwrap(checked(create).instances?.first).id
    var deleted = false
    defer {
        if !deleted {
            var stop = NativeControlRequest("stop"); stop.instanceID = instance; stop.operatorToken = workerToken
            _ = worker.handle(stop)
            stop.operation = "delete"; stop.confirmed = true; _ = worker.handle(stop)
        }
    }
    var exec = NativeControlRequest("exec"); exec.instanceID = instance
    exec.command = NativeCommand(["/usr/bin/printf", "index"])
    func wait(_ id: String) throws -> NativeExecutionRecord {
        var query = NativeControlRequest("execution"); query.executionID = id
        let deadline = Date(timeIntervalSinceNow: 10)
        while Date() < deadline {
            let record = try unwrap(checked(query).execution)
            if record.isTerminal { return record }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw SandboxError("index command did not finish")
    }
    let first = try unwrap(checked(exec).execution).id
    expectEqual(try wait(first).result?.stdout, Data("index".utf8))
    let index = state.appendingPathComponent("cluster/executions.json")
    let original = try SafeFiles.read([String: String].self, from: index)
    expectEqual(original[first], "worker")
    let instanceIndex = state.appendingPathComponent("cluster/instances.json")
    let instanceData = try SafeFiles.readRegular(instanceIndex, limit: 2 * 1024 * 1024)
    let result = workerState.appendingPathComponent("executions/\(first).json")
    let resultData = try SafeFiles.readRegular(result, limit: FramedChannel.messageLimit)
    control?.shutdown(); control = nil
    server.requestStop(); listeners.wait()
    var legacy = try JSON.data(original, pretty: true)
    legacy.append(Data(repeating: 0x20, count: 2 * 1024 * 1024))
    try SafeFiles.writeData(legacy, to: index)
    control = try manager(); token = try NativeControlClient.operatorToken(stateDirectory: state)
    expectTrue(try SafeFiles.read([String: String].self, from: index).isEmpty)
    expectEqual(try SafeFiles.readRegular(instanceIndex, limit: 2 * 1024 * 1024), instanceData)
    expectEqual(try SafeFiles.readRegular(result, limit: FramedChannel.messageLimit), resultData)
    server = try listen()
    var inspect = NativeControlRequest("inspect"); inspect.instanceID = instance
    expectEqual(try checked(inspect).instance?.id, instance)
    var history = NativeControlRequest("executions"); history.instanceID = instance
    expectTrue(try checked(history).executions?.contains { $0.id == first } == true)
    expectEqual(try wait(first).result?.stdout, Data("index".utf8))
    let second = try unwrap(checked(exec).execution).id
    expectNotEqual(first, second)
    expectEqual(try wait(second).state, "succeeded")
    expectEqual(try SafeFiles.read([String: String].self, from: index)[second], "worker")
    var remove = NativeControlRequest("stop"); remove.instanceID = instance
    _ = try checked(remove)
    remove.operation = "delete"; remove.confirmed = true
    expectTrue(try checked(remove).instance?.state == .deleted); deleted = true
    guard assertionFailures.isEmpty else { throw SandboxError("cluster index tests failed") }
    print("PASS: startup clears oversized execution index; instance routes and results survive; history and new commands rebuild routes")
}

func runClusterReadRetryTests(bin: URL, output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SandboxError("retry output must be new") }
    try SafeFiles.secureDirectory(output)
    let coordination = output.appendingPathComponent("ipc")
    try SafeFiles.secureDirectory(coordination)
    let previous = ProcessInfo.processInfo.environment["METAL_SANDBOX_COORDINATION_DIR"]
    setenv("METAL_SANDBOX_COORDINATION_DIR", coordination.path, 1)
    defer { if let previous { setenv("METAL_SANDBOX_COORDINATION_DIR", previous, 1) } else { unsetenv("METAL_SANDBOX_COORDINATION_DIR") } }
    let workerState = output.appendingPathComponent("worker")
    let worker = try NativeManager(directory: workerState, binDirectory: bin, coordinationDirectory: output.appendingPathComponent("worker_coord"))
    defer { worker.shutdown() }
    let listeners = DispatchGroup()
    func listen() throws -> NativeControlServer {
        let server = NativeControlServer(transfer: worker.transfer) { worker.handle($0) }
        let ready = DispatchSemaphore(value: 0)
        listeners.enter()
        DispatchQueue.global().async {
            defer { listeners.leave() }
            do { try server.serve { ready.signal() } }
            catch { FileHandle.standardError.write(Data("retry listener: \(error)\n".utf8)); ready.signal() }
        }
        guard ready.wait(timeout: .now() + 5) == .success else { throw SandboxError("retry listener did not start") }
        return server
    }
    var server = try listen()
    defer { server.requestStop(); listeners.wait() }
    let transport = LocalRelayTransport(bin: bin, environment: ProcessInfo.processInfo.environment)
    let node = ClusterNode(id: "worker", sshDestination: "unused", cliPath: bin.appendingPathComponent("sandboxctl").path, stateDirectory: workerState.path)
    let local = try NativeManager(directory: output.appendingPathComponent("manager"), binDirectory: bin, coordinationDirectory: output.appendingPathComponent("manager_coord"))
    defer { local.shutdown() }
    let controller = try ClusterController(configuration: ClusterConfiguration(localNodeID: "manager", nodes: [node]),
                                           directory: output.appendingPathComponent("controller"), transport: transport) { local.handle($0) }
    defer { controller.close() }
    var create = NativeControlRequest("create"); create.count = 1; create.nodeID = "worker"
    let instance = try unwrap(controller.handle(create)?.instances?.first).id
    server.requestStop(); listeners.wait()
    let lock = NSLock()
    var attempts: [Double] = [], stops = 0
    transport.beforeRequest = { input in
        lock.lock(); defer { lock.unlock() }
        if input.operation == "inspect" {
            attempts.append(Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
            print("read attempt \(attempts.count)")
            fflush(stdout)
        }
        if input.operation == "stop" { stops += 1 }
    }
    var stop = NativeControlRequest("stop"); stop.instanceID = instance
    do { _ = try controller.handle(stop); throw SandboxError("offline mutating request succeeded") }
    catch let error as SandboxError where error.description.contains("cannot connect relay manager") {}
    expectEqual(stops, 1)
    let restored = DispatchSemaphore(value: 0)
    var restoreError: Error?
    DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
        do { server = try listen() }
        catch { restoreError = error }
        restored.signal()
    }
    var inspect = NativeControlRequest("inspect"); inspect.instanceID = instance
    let reply = try controller.handle(inspect)
    guard restored.wait(timeout: .now() + 5) == .success else { throw SandboxError("retry listener was not restored") }
    if let restoreError { throw restoreError }
    expectEqual(reply?.instance?.id, instance)
    lock.lock(); let times = attempts; lock.unlock()
    let expected: [Double] = [0.5, 1, 2, 4, 8, 16, 32, 64, 128, 256]
    expectEqual(times.count, expected.count + 1)
    let observed = zip(times.dropFirst(), times).map { $0 - $1 }
    for (actual, delay) in zip(observed, expected) {
        guard actual >= delay, actual < delay + 5 else { throw SandboxError("unexpected retry interval: \(actual), expected \(delay)") }
    }
    guard inspect.responseTimeout > expected.reduce(0, +) + Double(times.count) * 120 else { throw SandboxError("caller deadline cuts off relay retries") }
    inspect.localOnly = true; expectEqual(inspect.responseTimeout, 120)
    let token = try NativeControlClient.operatorToken(stateDirectory: workerState)
    stop.operatorToken = token; expectTrue(worker.handle(stop).ok)
    var delete = stop; delete.operation = "delete"; delete.confirmed = true
    expectTrue(worker.handle(delete).ok)
    try SafeFiles.write(["expected_intervals_seconds": expected, "observed_intervals_seconds": observed], to: output.appendingPathComponent("report.json"))
    print("PASS: ten real relay retries, same instance after recovery, mutating request attempted once")
}

private func checkControlBurst(state: URL) throws {
    var clients: [(Int32, FramedChannel, NativeControlRequest)] = []
    defer { for (fd, _, _) in clients { close(fd) } }
    let token = try NativeControlClient.operatorToken(stateDirectory: state)
    for _ in 0..<40 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SandboxError("cannot create burst client") }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(NativePaths.socket.path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SandboxError("burst socket path too long") }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { throw SandboxError("burst connection failed") }
            var request = NativeControlRequest("status"); request.operatorToken = token
            clients.append((fd, try FramedChannel(input: fd, output: fd), request))
        } catch { close(fd); throw error }
    }
    // 真实客户端先连接再发送，在正常读取超时内覆盖 32 个处理连接被占满的情况。
    Thread.sleep(forTimeInterval: 0.2)
    for (_, channel, request) in clients { try channel.send(request) }
    for (_, channel, request) in clients {
        let reply = try unwrap(channel.receive(NativeControlReply.self, timeout: 10))
        expectTrue(reply.ok); expectEqual(reply.requestID, request.requestID)
        expectEqual(reply.status?.activeInstances, 0)
    }
}

func runClusterCapacityTests(bin: URL, output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SandboxError("capacity output must be new") }
    try SafeFiles.secureDirectory(output)
    let relay = output.appendingPathComponent("ipc")
    try SafeFiles.secureDirectory(relay)
    let prior = ProcessInfo.processInfo.environment["METAL_SANDBOX_COORDINATION_DIR"]
    setenv("METAL_SANDBOX_COORDINATION_DIR", relay.path, 1)
    defer { if let prior { setenv("METAL_SANDBOX_COORDINATION_DIR", prior, 1) } else { unsetenv("METAL_SANDBOX_COORDINATION_DIR") } }
    let workerState = output.appendingPathComponent("worker")
    let worker = try NativeManager(directory: workerState, binDirectory: bin, maxConcurrentInstances: 2, coordinationDirectory: output.appendingPathComponent("worker_coord"))
    defer { worker.shutdown() }
    let server = NativeControlServer(transfer: worker.transfer) { worker.handle($0) }
    let ready = DispatchSemaphore(value: 0), done = DispatchGroup()
    done.enter()
    DispatchQueue.global().async {
        defer { done.leave() }
        do { try server.serve { ready.signal() } }
        catch { FileHandle.standardError.write(Data("capacity listener: \(error)\n".utf8)); ready.signal() }
    }
    guard ready.wait(timeout: .now() + 5) == .success else { throw SandboxError("capacity relay did not start") }
    defer { server.requestStop(); done.wait() }
    try checkControlBurst(state: workerState)
    let transport = LocalRelayTransport(bin: bin, environment: ProcessInfo.processInfo.environment)
    let node = ClusterNode(id: "worker", sshDestination: "unused", cliPath: bin.appendingPathComponent("sandboxctl").path, stateDirectory: workerState.path, maxConcurrentInstances: 1)
    let configURL = output.appendingPathComponent("cluster.json")
    try SafeFiles.write(ClusterConfiguration(localNodeID: "manager", nodes: [node], maxConcurrentInstances: 1), to: configURL)
    let state = output.appendingPathComponent("manager")
    let manager = try NativeManager(directory: state, binDirectory: bin, clusterURL: configURL, clusterTransport: transport, coordinationDirectory: output.appendingPathComponent("manager_coord"))
    defer { manager.shutdown() }
    let token = try NativeControlClient.operatorToken(stateDirectory: state)
    func call(_ input: NativeControlRequest) -> NativeControlReply {
        var input = input; input.operatorToken = token; return manager.handle(input)
    }
    func checked(_ input: NativeControlRequest) throws -> NativeControlReply {
        let reply = call(input)
        guard reply.ok else { throw SandboxError(reply.error ?? "capacity request failed") }
        return reply
    }
    var create = NativeControlRequest("create"); create.count = 2
    let pair = try checked(create).instances ?? []
    expectEqual(Set(pair.compactMap(\.nodeID)), Set(["manager", "worker"]))
    expectEqual(manager.status.maxConcurrentInstances, 1); expectEqual(worker.status.maxConcurrentInstances, 2)
    create.count = 1
    expectEqual(call(create).errorCode, .instanceCapacityUnavailable)
    let original = try unwrap(pair.first { $0.nodeID == "manager" })
    var stop = NativeControlRequest("stop"); stop.instanceID = original.id
    _ = try checked(stop)
    let replacement = try unwrap(checked(create).instances?.first)
    expectEqual(replacement.nodeID, "manager")
    var start = stop; start.operation = "start"
    expectEqual(call(start).errorCode, .instanceCapacityUnavailable)
    var clone = stop; clone.operation = "restore"
    expectEqual(call(clone).errorCode, .instanceCapacityUnavailable)
    stop.instanceID = replacement.id; _ = try checked(stop)
    expectEqual(try checked(start).instance?.id, original.id)
    stop.instanceID = original.id; _ = try checked(stop)
    let cloned = try unwrap(checked(clone).instance)
    expectEqual(cloned.nodeID, "manager")
    stop.instanceID = cloned.id; _ = try checked(stop)
    stop.instanceID = try unwrap(pair.first { $0.nodeID == "worker" }).id; _ = try checked(stop)
    let group = DispatchGroup(), repliesLock = NSLock()
    var replies: [NativeControlReply] = []
    for _ in 0..<6 {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            var request = NativeControlRequest("create"); request.count = 1; request.operatorToken = token
            let reply = manager.handle(request)
            repliesLock.lock(); replies.append(reply); repliesLock.unlock()
        }
    }
    group.wait()
    expectEqual(replies.filter(\.ok).count, 2)
    expectEqual(replies.filter { $0.errorCode == .instanceCapacityUnavailable }.count, 4)
    expectEqual(manager.status.activeInstances, 1); expectEqual(worker.status.activeInstances, 1)
    let workerToken = try NativeControlClient.operatorToken(stateDirectory: workerState)
    var direct = NativeControlRequest("create"); direct.count = 1; direct.operatorToken = workerToken
    expectTrue(worker.handle(direct).ok)
    expectEqual(worker.handle(direct).errorCode, .instanceCapacityUnavailable)
    let process = Process(); process.executableURL = bin.appendingPathComponent("sandboxctl")
    process.arguments = ["--state-dir", workerState.path, "sandbox", "create", "--count", "1"]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit(); expectEqual(process.terminationStatus, 75)
    let records = try checked(NativeControlRequest("list")).instances ?? []
    for record in records where record.state == .active { stop.instanceID = record.id; _ = try checked(stop) }
    var oversized = NativeControlRequest("create"); oversized.count = 3
    expectEqual(call(oversized).errorCode, .instanceCapacityUnavailable)
    expectEqual(manager.status.activeInstances, 0); expectEqual(worker.status.activeInstances, 0)
    expectThrows(try ClusterConfiguration(localNodeID: "node", nodes: [], maxConcurrentInstances: -1).validate())
    try ClusterConfiguration(localNodeID: "node", nodes: [], maxConcurrentInstances: 64).validate()
    let disabled = try NativeManager(directory: output.appendingPathComponent("disabled"), binDirectory: bin, maxConcurrentInstances: 0, coordinationDirectory: output.appendingPathComponent("disabled_coord"))
    defer { disabled.shutdown() }
    direct.operatorToken = try NativeControlClient.operatorToken(stateDirectory: output.appendingPathComponent("disabled"))
    let refusal = disabled.handle(direct)
    expectFalse(refusal.ok); expectNil(refusal.errorCode)
    try SafeFiles.write(["assertionFailures": assertionFailures.joined(separator: "\n"), "checks": "40-client IPC burst, heterogeneous node limits, manager override, concurrent admission, start/clone, release, zero, CLI exit 75"], to: output.appendingPathComponent("report.json"))
    guard assertionFailures.isEmpty else { throw SandboxError("capacity checks failed") }
}

func runClusterTests(bin: URL, output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SandboxError("cluster test output must be new") }
    try SafeFiles.secureDirectory(output)
    let coordination = output.appendingPathComponent("relay")
    try SafeFiles.secureDirectory(coordination)
    let previousCoordination = ProcessInfo.processInfo.environment["METAL_SANDBOX_COORDINATION_DIR"]
    setenv("METAL_SANDBOX_COORDINATION_DIR", coordination.path, 1)
    defer {
        if let previousCoordination { setenv("METAL_SANDBOX_COORDINATION_DIR", previousCoordination, 1) }
        else { unsetenv("METAL_SANDBOX_COORDINATION_DIR") }
    }
    let shared = output.appendingPathComponent("shared")
    try SafeFiles.secureDirectory(shared)
    let policyURL = output.appendingPathComponent("task_policy.json")
    try SafeFiles.write(TaskPolicy(parallel: [.init("/bin/echo")]), to: policyURL)
    let node = ClusterNode(id: "worker", sshDestination: "unused", cliPath: bin.appendingPathComponent("sandboxctl").path,
        stateDirectory: output.appendingPathComponent("worker").path)
    let managerConfiguration = output.appendingPathComponent("manager_configuration.json")
    let workerConfiguration = output.appendingPathComponent("worker_configuration.json")
    try SafeFiles.write(ClusterConfiguration(localNodeID: "manager", sharedRoot: shared.path, nodes: []), to: managerConfiguration)
    try SafeFiles.write(ClusterConfiguration(localNodeID: "worker", sharedRoot: shared.path, nodes: []), to: workerConfiguration)
    let manager = try NativeManager(directory: output.appendingPathComponent("manager"), binDirectory: bin, taskPolicyURL: policyURL,
        clusterURL: managerConfiguration, coordinationDirectory: output.appendingPathComponent("coordination_a"))
    let worker = try NativeManager(directory: output.appendingPathComponent("worker"), binDirectory: bin, taskPolicyURL: policyURL,
        clusterURL: workerConfiguration, coordinationDirectory: output.appendingPathComponent("coordination_b"))
    let tokenA = try NativeControlClient.operatorToken(stateDirectory: output.appendingPathComponent("manager"))
    let tokenB = try NativeControlClient.operatorToken(stateDirectory: output.appendingPathComponent("worker"))
    let serverDone = DispatchGroup()
    func startServer() throws -> NativeControlServer {
        let server = NativeControlServer(transfer: worker.transfer) { worker.handle($0) }
        let ready = DispatchSemaphore(value: 0)
        serverDone.enter()
        DispatchQueue.global().async {
            defer { serverDone.leave() }
            do { try server.serve { ready.signal() } }
            catch { FileHandle.standardError.write(Data("cluster test listener: \(error)\n".utf8)); ready.signal() }
        }
        guard ready.wait(timeout: .now() + 5) == .success else { throw SandboxError("cluster relay test server did not start") }
        return server
    }
    var server = try startServer()
    defer { server.requestStop(); serverDone.wait() }
    let transport = LocalRelayTransport(bin: bin, environment: ProcessInfo.processInfo.environment)
    func local(_ input: NativeControlRequest) -> NativeControlReply {
        var input = input; input.operatorToken = tokenA; input.localOnly = true; return manager.handle(input)
    }
    var controller = try ClusterController(configuration: ClusterConfiguration(localNodeID: "manager", sharedRoot: shared.path, nodes: [node]),
        directory: output, transport: transport, local: local)
    var ids: [(String, String)] = []
    defer {
        for (id, owner) in ids {
            var stop = NativeControlRequest("stop"); stop.instanceID = id; stop.operatorToken = owner == "manager" ? tokenA : tokenB
            let target = owner == "manager" ? manager : worker
            _ = target.handle(stop)
            var remove = stop; remove.operation = "delete"; remove.confirmed = true; _ = target.handle(remove)
        }
        manager.shutdown(); worker.shutdown(); controller.close()
    }
    func checked(_ reply: NativeControlReply) throws -> NativeControlReply {
        guard reply.ok else { throw SandboxError(reply.error ?? "test request failed") }; return reply
    }
    func create(owner: String? = nil, dynamic: Bool = false) throws -> NativeInstanceRecord {
        var request = NativeControlRequest("create"); request.count = 1; request.nodeID = owner; request.dynamicScheduling = dynamic
        let record = try unwrap(checked(try unwrap(controller.handle(request))).instances?.first)
        ids.append((record.id, record.nodeID!)); return record
    }
    func execute(_ instance: NativeInstanceRecord, _ script: String, session: Bool = false, timeout: Double = 10) throws -> String {
        var request = NativeControlRequest("exec"); request.instanceID = instance.id
        var command = NativeCommand(["/bin/bash", "-c", script], timeoutSeconds: timeout)
        command.agentSession = session; request.command = command
        let reply = try controller.handle(request) ?? local(request)
        return try unwrap(checked(reply).execution).id
    }
    func state(_ id: String, owner: String) throws -> NativeExecutionRecord {
        var request = NativeControlRequest("execution"); request.executionID = id
        let reply: NativeControlReply
        if owner == "manager" { reply = local(request) } else { reply = try transport.request(request, node: node) }
        return try unwrap(checked(reply).execution)
    }
    func wait(_ id: String, owner: String, timeout: Double = 25) throws -> NativeExecutionRecord {
        let end = Date(timeIntervalSinceNow: timeout)
        while Date() < end {
            let value = try state(id, owner: owner)
            if value.isTerminal { return value }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw SandboxError("cluster test execution did not finish: \(id)")
    }
    print("CLUSTER instance placement through two real managers")
    let first = try create(), second = try create()
    expectNotEqual(first.nodeID, second.nodeID)
    let statuses = controller.refresh()
    expectEqual(statuses.compactMap { $0.status?.activeInstances }.sorted(), [1, 1])
    let placement = ClusterPlacement()
    let a = try placement.reserve(nodes: statuses), b = try placement.reserve(nodes: statuses)
    expectNotEqual(a, b); placement.release(a); placement.release(b)
    var capacity = statuses
    capacity[0].status?.activeInstances = 32
    expectFalse(capacity[0].available); expectTrue(capacity[0].readyForExecution)
    var batch = NativeControlRequest("create"); batch.count = 4; batch.name = "replica"
    let replicas = try unwrap(controller.handle(batch)).instances ?? []
    expectEqual(replicas.count, 4)
    for record in replicas { ids.append((record.id, record.nodeID!)) }
    expectEqual(replicas.compactMap(\.name), ["replica (1)", "replica (2)", "replica (3)", "replica (4)"])
    expectEqual(replicas.filter { $0.nodeID == "manager" }.count, 2)
    expectEqual(replicas.filter { $0.nodeID == "worker" }.count, 2)
    expectThrows(try ClusterConfiguration(localNodeID: "manager", nodes: [node, node]).validate())
    let arguments = try SSHClusterTransport.arguments(node)
    expectTrue(arguments.contains("BatchMode=yes")); expectTrue(arguments.contains("StrictHostKeyChecking=yes"))
    var bad = node; bad.sshDestination = "-oProxyCommand=command"
    expectThrows(try SSHClusterTransport.arguments(bad))

    print("CLUSTER queued serial handoff and shared workspace writes")
    let dynamic = try create(owner: "manager", dynamic: true)
    let blocked = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 6")
    let end = Date(timeIntervalSinceNow: 3)
    while manager.status.executionCounts.serialRunning != 1 && Date() < end { Thread.sleep(forTimeInterval: 0.03) }
    let migrated = try execute(dynamic, "printf '%s' remote-result > result.txt; /bin/cat result.txt")
    let result = try wait(migrated, owner: "manager")
    expectEqual(result.state, "succeeded")
    expectEqual(String(decoding: try unwrap(result.result).stdout, as: UTF8.self), "remote-result")
    expectTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("worker/cluster_jobs").path))
    let jobs = try FileManager.default.contentsOfDirectory(at: output.appendingPathComponent("worker/cluster_jobs"), includingPropertiesForKeys: nil)
    expectEqual(jobs.count, 1)
    expectFalse(try state(blocked, owner: "manager").isTerminal)
    var read = NativeControlRequest("read"); read.instanceID = dynamic.id; read.path = "result.txt"
    expectEqual(try checked(local(read)).file?.data, Data("remote-result".utf8))
    _ = try wait(blocked, owner: "manager")

    print("CLUSTER unavailable forwarding dependencies prevent remote dispatch")
    var dependency = NativeControlRequest("port-forward-require")
    dependency.instanceID = dynamic.id; dependency.forwardID = UUID().uuidString.lowercased(); dependency.confirmed = true
    _ = try checked(local(dependency))
    let forwardBlock = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 6")
    let forwardBusy = Date(timeIntervalSinceNow: 3)
    while manager.status.executionCounts.serialRunning != 1 && Date() < forwardBusy { Thread.sleep(forTimeInterval: 0.03) }
    let guarded = try execute(dynamic, "printf forwarding-guard")
    Thread.sleep(forTimeInterval: 1.3)
    expectEqual(try state(guarded, owner: "manager").state, "queued")
    let pending = try checked(local(NativeControlRequest("cluster-pending"))).clusterTasks ?? []
    expectTrue(pending.contains { $0.instanceID == dynamic.id && $0.loopbackForwardIDs == [dependency.forwardID!] })
    dependency.confirmed = false; _ = try checked(local(dependency))
    expectEqual(try wait(guarded, owner: "manager").state, "succeeded")
    expectFalse(try state(forwardBlock, owner: "manager").isTerminal)
    _ = try wait(forwardBlock, owner: "manager")

    print("CLUSTER opt-out stays queued; parallel tasks remain local")
    let holding = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 3")
    let ordinary = try execute(first.nodeID == "manager" ? first : second, "printf local")
    Thread.sleep(forTimeInterval: 0.3)
    expectEqual(try state(ordinary, owner: "manager").state, "queued")
    var parallel = NativeControlRequest("exec"); parallel.instanceID = dynamic.id; parallel.command = NativeCommand(["/bin/echo", "parallel"])
    let parallelID = try unwrap(checked(local(parallel)).execution).id
    expectEqual(try wait(parallelID, owner: "manager").state, "succeeded")
    _ = try wait(holding, owner: "manager"); _ = try wait(ordinary, owner: "manager")

    print("CLUSTER harness child command passes through shared scheduler")
    let blocking = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 5")
    Thread.sleep(forTimeInterval: 0.1)
    let session = try execute(dynamic, "\"$METAL_SANDBOX_SHELL_HELPER\" 'printf nested > nested.txt; /bin/cat nested.txt'", session: true)
    let nested = try wait(session, owner: "manager")
    expectEqual(nested.state, "succeeded")
    expectTrue(String(decoding: try unwrap(nested.result).stdout, as: UTF8.self).contains("nested"))
    expectFalse(try state(blocking, owner: "manager").isTerminal)
    _ = try wait(blocking, owner: "manager")

    print("CLUSTER native harness client paths do not prevent tool migration")
    for harness in ["claude", "codex"] {
        let blocker = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 6")
        let busy = Date(timeIntervalSinceNow: 3)
        while manager.status.executionCounts.serialRunning != 1 && Date() < busy { Thread.sleep(forTimeInterval: 0.02) }
        let privateValues = harness == "claude"
            ? "CLAUDE_CODE_TMPDIR=\"$METAL_SANDBOX_BRIDGE_DIRECTORY/claude\" CLAUDE_CODE_SHELL_PREFIX=sandbox-shell PATH=\"${METAL_SANDBOX_SHELL_HELPER%/*}:/usr/bin:/bin\""
            : "CODEX_CODE_MODE_HOST=\"$METAL_SANDBOX_BRIDGE_DIRECTORY/code-mode-host\" PATH=/usr/bin:/bin"
        let clean = "test -z \"${CLAUDE_CODE_TMPDIR:-}${CLAUDE_CODE_SHELL_PREFIX:-}${CODEX_CODE_MODE_HOST:-}\" && printf \"%s\\n\" \"$CUSTOM_VALUE\" > harness_\(harness).txt; /bin/cat harness_\(harness).txt"
        let launch = "/usr/bin/env -i HOME=\"$HOME\" TMPDIR=\"$TMPDIR\" WORKSPACE=\"$WORKSPACE\" METAL_SANDBOX_WORKSPACE=\"$METAL_SANDBOX_WORKSPACE\" METAL_SANDBOX_BRIDGE_DIRECTORY=\"$METAL_SANDBOX_BRIDGE_DIRECTORY\" METAL_SANDBOX_SHELL_HELPER=\"$METAL_SANDBOX_SHELL_HELPER\" METAL_SANDBOX_AGENT_SESSION=\"$METAL_SANDBOX_AGENT_SESSION\" METAL_SANDBOX_JOB_ID=\"$METAL_SANDBOX_JOB_ID\" METAL_SANDBOX_HARNESS=\(harness) CUSTOM_VALUE=retained \(privateValues) \"$METAL_SANDBOX_SHELL_HELPER\" '\(clean)'"
        let before = try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("worker/cluster_jobs").path).count
        let job = try execute(dynamic, launch, session: true)
        let completed = try wait(job, owner: "manager")
        expectEqual(completed.state, "succeeded")
        expectEqual(String(decoding: try unwrap(completed.result).stdout, as: UTF8.self), "retained\n")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("worker/cluster_jobs").path).count, before + 1)
        expectFalse(try state(blocker, owner: "manager").isTerminal)
        _ = try wait(blocker, owner: "manager")
        let local = try execute(dynamic, launch, session: true)
        expectEqual(String(decoding: try unwrap(try wait(local, owner: "manager").result).stdout, as: UTF8.self), "retained\n")
    }

    if let bundle = ProcessInfo.processInfo.environment["MINI_METAL_TEST_BUNDLE"] {
        print("CLUSTER uploaded mini runtime keeps client dependencies local and migrates tools")
        let miniWorkspace = try unwrap(dynamic.sharedWorkspace).workspace
        try FileManager.default.copyItem(at: URL(fileURLWithPath: bundle), to: miniWorkspace.appendingPathComponent("mini_runtime.tar.gz"))
        var upload = NativeControlRequest("write"); upload.instanceID = dynamic.id
        upload.file = WorkspaceFile(path: "mini_swe_agent_metal.py", data: try Data(contentsOf: URL(fileURLWithPath: "examples/harnesses/mini_swe_agent_metal.py")))
        _ = try checked(local(upload))
        let python = #"""
        import json, os
        from litellm.litellm_core_utils import default_encoding
        from mini_swe_agent_metal import MetalEnvironment
        runtime = os.environ["METAL_SANDBOX_MINI_RUNTIME"]
        assert os.environ["TIKTOKEN_CACHE_DIR"].startswith(runtime + "/")
        result = MetalEnvironment(env={"CUSTOM_VALUE": "mini-retained"}).execute({"command": 'test -z "${TIKTOKEN_CACHE_DIR:-}${UV_TOOL_DIR:-}" && printf "%s\\n%s\\n" "$CUSTOM_VALUE" "$METAL_SANDBOX_CONTAINER_HOME"'})
        print(json.dumps(result))
        """#
        upload.file = WorkspaceFile(path: "mini_cluster.py", data: Data(python.utf8)); _ = try checked(local(upload))
        let privatePython = #"""
        import json, os
        from mini_swe_agent_metal import MetalEnvironment
        runtime = os.environ["METAL_SANDBOX_MINI_RUNTIME"]
        result = MetalEnvironment(env={"PYTHONPATH": runtime + "/packages", "PRIVATE_FILE": runtime + "/owner_only"}).execute({"command": '/bin/cat "$PRIVATE_FILE"'})
        print(json.dumps(result))
        """#
        upload.file = WorkspaceFile(path: "mini_private.py", data: Data(privatePython.utf8)); _ = try checked(local(upload))
        let install = try execute(dynamic, "runtime=\"$METAL_SANDBOX_BRIDGE_DIRECTORY/mini-test\"; mkdir -p \"$runtime\"; tar -xzf mini_runtime.tar.gz -C \"$runtime\"; printf private > \"$runtime/owner_only\"", timeout: 120)
        expectEqual(try wait(install, owner: "manager", timeout: 130).state, "succeeded")
        let blocker = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 20", timeout: 30)
        let busy = Date(timeIntervalSinceNow: 3)
        while manager.status.executionCounts.serialRunning != 1 && Date() < busy { Thread.sleep(forTimeInterval: 0.02) }
        let launch = "runtime=\"$METAL_SANDBOX_BRIDGE_DIRECTORY/mini-test\"; export METAL_SANDBOX_MINI_RUNTIME=\"$runtime\" PYTHONPATH=\"$runtime/packages:$WORKSPACE\" UV_TOOL_DIR=\"$runtime/tools\" MSWEA_SILENT_STARTUP=1; \"$runtime/python/bin/python3\" "
        let before = try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("worker/cluster_jobs").path).count
        let remote = try execute(dynamic, launch + "mini_cluster.py", session: true, timeout: 30)
        let result = try wait(remote, owner: "manager", timeout: 40)
        expectEqual(result.state, "succeeded")
        struct MiniReport: Decodable { let returncode: Int; let output: String }
        let report = try JSONDecoder().decode(MiniReport.self, from: try unwrap(result.result).stdout)
        expectEqual(report.returncode, 0)
        let lines = report.output.split(separator: "\n").map(String.init)
        expectTrue(lines.count >= 2); expectEqual(lines.first, "mini-retained")
        if lines.count >= 2 { expectNotEqual(lines[1], dynamic.physical?.home) }
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("worker/cluster_jobs").path).count, before + 1)
        expectFalse(try state(blocker, owner: "manager").isTerminal)
        let retained = try execute(dynamic, launch + "mini_private.py", session: true, timeout: 30)
        let retainedResult = try wait(retained, owner: "manager", timeout: 40)
        expectEqual(retainedResult.state, "succeeded")
        let retainedReport = try JSONDecoder().decode(MiniReport.self, from: try unwrap(retainedResult.result).stdout)
        expectEqual(retainedReport.returncode, 0); expectTrue(retainedReport.output.hasPrefix("private"))
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("worker/cluster_jobs").path).count, before + 1)
        _ = try wait(blocker, owner: "manager")
    }

    print("CLUSTER remote cancellation releases only the target slot")
    let cancelBlock = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 8")
    Thread.sleep(forTimeInterval: 0.1)
    let cancelID = try execute(dynamic, "/bin/sleep 20", timeout: 30)
    let cancellationDeadline = Date(timeIntervalSinceNow: 8)
    while try state(cancelID, owner: "manager").state != "running" && Date() < cancellationDeadline { Thread.sleep(forTimeInterval: 0.03) }
    expectEqual(try state(cancelID, owner: "manager").state, "running")
    var cancel = NativeControlRequest("cancel"); cancel.executionID = cancelID
    _ = try checked(local(cancel))
    expectEqual(try wait(cancelID, owner: "manager").state, "cancelled")
    expectNil(worker.status.recoveryReason)
    _ = try wait(cancelBlock, owner: "manager")

    print("CLUSTER remote execution timeout excludes source queue wait")
    let timeoutBlock = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 6")
    Thread.sleep(forTimeInterval: 0.1)
    let short = try execute(dynamic, "/bin/sleep 0.1", timeout: 0.3)
    expectEqual(try wait(short, owner: "manager").state, "succeeded")
    let timed = try execute(dynamic, "/bin/sleep 5", timeout: 0.2)
    let timedResult = try wait(timed, owner: "manager")
    expectEqual(timedResult.result?.outcome.reason, .timedOut)
    expectNil(manager.status.recoveryReason); expectNil(worker.status.recoveryReason)
    _ = try wait(timeoutBlock, owner: "manager")

    print("CLUSTER cancelling a harness session cancels its remote child")
    let childBlock = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 6")
    Thread.sleep(forTimeInterval: 0.1)
    let childParent = try execute(dynamic, "\"$METAL_SANDBOX_SHELL_HELPER\" '/bin/sleep 10'", session: true, timeout: 20)
    let childDeadline = Date(timeIntervalSinceNow: 8)
    while worker.status.executionCounts.serialRunning != 1 && Date() < childDeadline { Thread.sleep(forTimeInterval: 0.03) }
    expectEqual(worker.status.executionCounts.serialRunning, 1)
    cancel.executionID = childParent
    _ = try checked(local(cancel))
    expectEqual(try wait(childParent, owner: "manager").state, "cancelled")
    _ = try wait(childBlock, owner: "manager")
    let childFinished = Date(timeIntervalSinceNow: 5)
    while worker.status.executionCounts.total != 0 && Date() < childFinished { Thread.sleep(forTimeInterval: 0.03) }
    expectEqual(worker.status.executionCounts.total, 0)
    expectNil(manager.status.recoveryReason); expectNil(worker.status.recoveryReason)

    print("CLUSTER idempotent reserve/commit and shared identity rejection")
    let config = try unwrap(dynamic.sharedWorkspace)
    expectEqual(config.storageNodeID, dynamic.nodeID)
    expectEqual(config.directory.path, shared.appendingPathComponent(dynamic.nodeID!).appendingPathComponent(dynamic.id).path)
    expectThrows(try SharedWorkspace(root: shared.path, instanceID: dynamic.id, storageNodeID: "../worker"))
    let movedIdentity = try SharedWorkspace(root: shared.path, instanceID: dynamic.id, identity: config.identity, storageNodeID: "unmounted_peer")
    expectThrows(try movedIdentity.verify())
    var task = ClusterTask(instanceID: dynamic.id, workspace: config,
        command: NativeCommand(["/bin/bash", "-c", "printf x >> once.txt"]), environment: [:], networkClient: false, taskPolicy: TaskPolicy())
    var reserve = NativeControlRequest("cluster-reserve"); reserve.clusterTask = task
    let reservation = try unwrap(checked(transport.request(reserve, node: node)).clusterReservation)
    expectEqual(try checked(transport.request(reserve, node: node)).clusterReservation?.id, reservation.id)
    var commit = NativeControlRequest("cluster-commit"); commit.clusterTask = task; commit.reservationID = reservation.id
    _ = try checked(transport.request(commit, node: node)); _ = try checked(transport.request(commit, node: node))
    var query = NativeControlRequest("cluster-result"); query.executionID = task.id
    let completeDeadline = Date(timeIntervalSinceNow: 5)
    while ["queued", "running"].contains(try checked(transport.request(query, node: node)).clusterUpdate?.state ?? "") && Date() < completeDeadline { Thread.sleep(forTimeInterval: 0.03) }
    _ = try checked(transport.request(commit, node: node))
    read.path = "once.txt"
    expectEqual(try checked(local(read)).file?.data, Data("x".utf8))
    task.workspace = try SharedWorkspace(root: shared.path, instanceID: dynamic.id)
    task.id = UUID().uuidString.lowercased(); reserve.clusterTask = task
    expectFalse(try transport.request(reserve, node: node).ok)

    print("CLUSTER controller restart resumes the same task")
    let restartBlock = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 10")
    Thread.sleep(forTimeInterval: 0.1)
    let restartJob = try execute(dynamic, "/bin/sleep 3; printf resume >> resumed.txt")
    let startDeadline = Date(timeIntervalSinceNow: 8)
    while try state(restartJob, owner: "manager").state != "running" && Date() < startDeadline { Thread.sleep(forTimeInterval: 0.03) }
    expectEqual(try state(restartJob, owner: "manager").state, "running")
    controller.close()
    controller = try ClusterController(configuration: ClusterConfiguration(localNodeID: "manager", sharedRoot: shared.path, nodes: [node]),
        directory: output, transport: transport, local: local)
    expectEqual(try wait(restartJob, owner: "manager").state, "succeeded")
    read.path = "resumed.txt"
    expectEqual(try checked(local(read)).file?.data, Data("resume".utf8))
    _ = try wait(restartBlock, owner: "manager")

    print("CLUSTER connection loss retains execution identity and reconnects")
    let disconnectBlock = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 12")
    Thread.sleep(forTimeInterval: 0.1)
    let disconnectJob = try execute(dynamic, "/bin/sleep 4; printf reconnect >> reconnect.txt")
    let disconnectDeadline = Date(timeIntervalSinceNow: 8)
    while try state(disconnectJob, owner: "manager").state != "running" && Date() < disconnectDeadline { Thread.sleep(forTimeInterval: 0.03) }
    expectEqual(try state(disconnectJob, owner: "manager").state, "running")
    _ = try controller.handle(NativeControlRequest("list"))
    server.requestStop(); serverDone.wait()
    Thread.sleep(forTimeInterval: 1.5)
    expectThrows(try transport.request(NativeControlRequest("status"), node: node))
    let disconnected = controller.refresh()
    expectTrue(disconnected.first { $0.id == "worker" }?.error != nil)
    let offline = try unwrap(disconnected.first { $0.id == "worker" })
    expectNil(offline.status)
    expectEqual(offline.lastKnownStatus?.host.modelIdentifier, worker.status.host.modelIdentifier)
    expectEqual(controller.refresh().first { $0.id == "worker" }?.lastKnownStatus?.host.modelIdentifier,
                worker.status.host.modelIdentifier)
    expectThrows(try placement.reserve(nodes: disconnected, preferred: "worker"))
    let retained = try unwrap(controller.handle(NativeControlRequest("list"))).instances ?? []
    expectTrue(retained.contains { $0.id == second.id && $0.nodeID == "worker" && $0.availableActions == [] })
    server = try startServer()
    let reconnected = try unwrap(controller.refresh().first { $0.id == "worker" })
    expectTrue(reconnected.status != nil)
    expectNil(reconnected.error)
    expectNil(reconnected.lastKnownStatus)
    expectEqual(try wait(disconnectJob, owner: "manager").state, "succeeded")
    read.path = "reconnect.txt"
    expectEqual(try checked(local(read)).file?.data, Data("reconnect".utf8))
    _ = try wait(disconnectBlock, owner: "manager")

    print("CLUSTER worker-owned task can move to the manager")
    let remoteInstance = try create(owner: "worker", dynamic: true)
    let remoteBlock = try execute(first.nodeID == "worker" ? first : second, "/bin/sleep 5")
    let runningDeadline = Date(timeIntervalSinceNow: 3)
    while worker.status.executionCounts.serialRunning != 1 && Date() < runningDeadline { Thread.sleep(forTimeInterval: 0.03) }
    let reverse = try execute(remoteInstance, "printf reverse > reverse.txt")
    expectEqual(try wait(reverse, owner: "worker").state, "succeeded")
    expectFalse(try state(remoteBlock, owner: "worker").isTerminal)
    _ = try wait(remoteBlock, owner: "worker")
    var inspect = NativeControlRequest("inspect"); inspect.instanceID = remoteInstance.id
    expectEqual(try unwrap(controller.handle(inspect)).instance?.nodeID, "worker")
    var grant = NativeControlRequest("grant"); grant.instanceID = remoteInstance.id; grant.operations = [.read]
    let remoteHandle = try unwrap(try unwrap(controller.handle(grant)).handle)
    var scopedRead = NativeControlRequest("read"); scopedRead.instanceID = remoteInstance.id; scopedRead.path = "reverse.txt"; scopedRead.handle = remoteHandle
    expectEqual(try unwrap(controller.handle(scopedRead)).file?.data, Data("reverse".utf8))
    var scopedWrite = scopedRead; scopedWrite.operation = "write"; scopedWrite.file = WorkspaceFile(path: "denied.txt", data: Data())
    expectThrows(try controller.handle(scopedWrite))

    print("CLUSTER Metal work executes inside the target App Sandbox")
    let metalBlock = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 6")
    Thread.sleep(forTimeInterval: 0.1)
    let gpu = try execute(dynamic, "\"${METAL_SANDBOX_SHELL_HELPER%/*}/metal-runner\" --render-smoke", timeout: 30)
    let gpuResult = try wait(gpu, owner: "manager", timeout: 40)
    expectEqual(gpuResult.state, "succeeded")
    struct MetalReport: Decodable { let device: String; let readbackCorrect: Bool; let frames: Int }
    let metal = try JSONDecoder().decode(MetalReport.self, from: try unwrap(gpuResult.result).stdout)
    expectTrue(metal.readbackCorrect); expectEqual(metal.frames, 1000); expectFalse(metal.device.isEmpty)
    _ = try wait(metalBlock, owner: "manager")
    expectNil(manager.status.recoveryReason); expectNil(worker.status.recoveryReason)

    print("CLUSTER compile and execute a candidate in the shared workspace")
    var source = NativeControlRequest("write"); source.instanceID = dynamic.id
    source.file = WorkspaceFile(path: "candidate.c", data: Data("#include <stdio.h>\nint main(void) { puts(\"compiled-candidate\"); return 0; }\n".utf8))
    _ = try checked(local(source))
    let compilerBlock = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 6")
    Thread.sleep(forTimeInterval: 0.1)
    let compiled = try execute(dynamic, "\"$CC\" -isysroot \"$SDKROOT\" candidate.c -o candidate && ./candidate", timeout: 30)
    let compiledResult = try wait(compiled, owner: "manager")
    expectEqual(compiledResult.state, "succeeded")
    expectEqual(String(decoding: try unwrap(compiledResult.result).stdout, as: UTF8.self), "compiled-candidate\n")
    _ = try wait(compilerBlock, owner: "manager")
    let installLocal = try execute(dynamic, "/bin/mkdir -p \"$HOME/.local/bin\"; /bin/cp candidate \"$HOME/.local/bin/instance_tool\"")
    expectEqual(try wait(installLocal, owner: "manager").state, "succeeded")
    var instanceTool = NativeControlRequest("exec"); instanceTool.instanceID = dynamic.id
    instanceTool.command = NativeCommand(["instance_tool"])
    let instanceToolID = try unwrap(checked(local(instanceTool)).execution).id
    expectEqual(try wait(instanceToolID, owner: "manager").result?.stdout, Data("compiled-candidate\n".utf8))

    print("CLUSTER preserves shared PATH and user variables for direct and harness commands")
    let prepareEnvironment = try execute(dynamic, "mkdir -p shared_bin; cp candidate shared_bin/shared_tool; printf owner-only > \"$METAL_SANDBOX_BRIDGE_DIRECTORY/owner_only\"; cp candidate \"$METAL_SANDBOX_BRIDGE_DIRECTORY/private_tool\"", timeout: 20)
    expectEqual(try wait(prepareEnvironment, owner: "manager").state, "succeeded")
    let environmentScript = "printf '%s\\n' \"$CUSTOM_VALUE\" \"$CC\" \"$CXX\" \"$SDKROOT\" \"$PATH\" \"$METAL_SANDBOX_CONTAINER_HOME\"; shared_tool"
    source.file = WorkspaceFile(path: "environment_probe.sh", data: Data(environmentScript.utf8))
    _ = try checked(local(source))
    var values = manager.status.toolchain.environment
    let sharedBin = config.workspace.appendingPathComponent("shared_bin").path
    values["PATH"] = sharedBin + ":" + values["PATH"]!
    values["CUSTOM_VALUE"] = "user value 空格"
    func executeEnvironment(_ command: NativeCommand, values: [String: String]) throws -> String {
        var request = NativeControlRequest("exec"); request.instanceID = dynamic.id
        var command = command; command.environment = values; request.command = command
        return try unwrap(checked(local(request)).execution).id
    }
    let environmentBlock = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 12", timeout: 20)
    let environmentBusy = Date(timeIntervalSinceNow: 3)
    while manager.status.executionCounts.serialRunning != 1 && Date() < environmentBusy { Thread.sleep(forTimeInterval: 0.02) }
    for session in [false, true] {
        var command = NativeCommand(["/bin/bash", "-c", session ? "\"$METAL_SANDBOX_SHELL_HELPER\" '/bin/bash ./environment_probe.sh'" : "/bin/bash ./environment_probe.sh"], timeoutSeconds: 15)
        command.agentSession = session
        let eid = try executeEnvironment(command, values: values)
        let result = try wait(eid, owner: "manager")
        expectEqual(result.state, "succeeded")
        let lines = String(decoding: try unwrap(result.result).stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        expectEqual(lines.count, 7)
        if lines.count == 7 {
            expectEqual(lines[0], "user value 空格")
            expectEqual(lines[1], worker.status.toolchain.compiler)
            expectEqual(lines[2], worker.status.toolchain.cxxCompiler)
            expectEqual(lines[3], worker.status.toolchain.sdk)
            expectEqual(lines[4].components(separatedBy: ":").first, sharedBin)
            expectNotEqual(lines[5], dynamic.physical?.home)
            expectEqual(lines[6], "compiled-candidate")
        }
        expectFalse(try state(environmentBlock, owner: "manager").isTerminal)
    }
    _ = try wait(environmentBlock, owner: "manager")

    print("CLUSTER keeps source-private arguments, variables and PATH on their owning node")
    let privateDirectory = try unwrap(dynamic.physical).home + "/Library/Application Support/MetalSandbox/tmp"
    let privateFile = privateDirectory + "/owner_only"
    let privateCases: [(NativeCommand, [String: String], String)] = [
        (NativeCommand(["/bin/cat", privateFile]), [:], "owner-only"),
        (NativeCommand(["/bin/bash", "-c", "/bin/cat \"$PRIVATE_FILE\""]), ["PRIVATE_FILE": privateFile], "owner-only"),
        (NativeCommand(["/bin/bash", "-c", "private_tool"]), ["PATH": privateDirectory + ":/usr/bin:/bin"], "compiled-candidate\n"),
    ]
    for (command, variables, expected) in privateCases {
        let holding = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 3")
        let busy = Date(timeIntervalSinceNow: 3)
        while manager.status.executionCounts.serialRunning != 1 && Date() < busy { Thread.sleep(forTimeInterval: 0.02) }
        let eid = try executeEnvironment(command, values: variables)
        Thread.sleep(forTimeInterval: 1.2)
        expectEqual(try state(eid, owner: "manager").state, "queued")
        expectEqual(worker.status.executionCounts.serialRunning, 0)
        _ = try wait(holding, owner: "manager")
        let result = try wait(eid, owner: "manager")
        expectEqual(result.state, "succeeded")
        expectEqual(result.result?.stdout, Data(expected.utf8))
    }

    print("CLUSTER rebinds registered compiler and SDK arguments before target execution")
    let directCompilerBlock = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 6")
    Thread.sleep(forTimeInterval: 0.1)
    let directCompiler = NativeCommand([manager.status.toolchain.compiler, "-isysroot", manager.status.toolchain.sdk, "candidate.c", "-o", "direct_candidate"], timeoutSeconds: 20)
    let compilerID = try executeEnvironment(directCompiler, values: [:])
    expectEqual(try wait(compilerID, owner: "manager").state, "succeeded")
    expectFalse(try state(directCompilerBlock, owner: "manager").isTerminal)
    _ = try wait(directCompilerBlock, owner: "manager")
    expectEqual(try wait(execute(dynamic, "./direct_candidate"), owner: "manager").result?.stdout, Data("compiled-candidate\n".utf8))

    print("CLUSTER shared workspace survives stop/start and snapshot clone")
    var stopShared = NativeControlRequest("stop"); stopShared.instanceID = dynamic.id
    _ = try checked(local(stopShared))
    read.path = "result.txt"
    expectEqual(try checked(local(read)).file?.data, Data("remote-result".utf8))
    var startShared = stopShared; startShared.operation = "start"
    expectEqual(try checked(local(startShared)).instance?.id, dynamic.id)
    let restartedCommand = try execute(dynamic, "printf restarted")
    expectEqual(try wait(restartedCommand, owner: "manager").state, "succeeded")
    _ = try checked(local(stopShared))
    var clone = stopShared; clone.operation = "restore"
    let cloned = try unwrap(checked(local(clone)).instance)
    ids.append((cloned.id, "manager"))
    expectTrue(cloned.dynamicScheduling == true)
    expectNotEqual(cloned.sharedWorkspace?.directory.path, dynamic.sharedWorkspace?.directory.path)
    read.instanceID = cloned.id
    expectEqual(try checked(local(read)).file?.data, Data("remote-result".utf8))
    _ = try checked(local(startShared))

    print("CLUSTER expired reservation cannot launch and releases the slot")
    task.workspace = config; task.id = UUID().uuidString.lowercased(); reserve.clusterTask = task
    let expiring = try unwrap(checked(transport.request(reserve, node: node)).clusterReservation)
    Thread.sleep(until: expiring.expiresAt.addingTimeInterval(0.5))
    commit.clusterTask = task; commit.reservationID = expiring.id
    expectEqual(try transport.request(commit, node: node).errorCode, .clusterReservationExpired)
    let afterExpiry = try execute(remoteInstance, "printf after-expiry")
    expectEqual(try wait(afterExpiry, owner: "worker").state, "succeeded")

    print("CLUSTER withdrawal fences a reservation and cannot stop an executing task")
    task.id = UUID().uuidString.lowercased()
    task.command = NativeCommand(["/bin/bash", "-c", "printf x >> withdrawn.txt"])
    reserve.clusterTask = task
    let withdrawn = try unwrap(checked(transport.request(reserve, node: node)).clusterReservation)
    var withdraw = NativeControlRequest("cluster-withdraw")
    withdraw.executionID = task.id; withdraw.reservationID = withdrawn.id
    expectTrue(try checked(transport.request(withdraw, node: node)).confirmed == true)
    expectTrue(try checked(transport.request(withdraw, node: node)).confirmed == true)
    commit.clusterTask = task; commit.reservationID = withdrawn.id
    expectEqual(try transport.request(commit, node: node).errorCode, .clusterReservationExpired)
    expectFalse(FileManager.default.fileExists(atPath: config.workspace.appendingPathComponent("withdrawn.txt").path))
    let executionToken = CancellationToken()
    expectTrue(executionToken.beginExecution()); expectFalse(executionToken.cancelBeforeExecution())
    let cancelledToken = CancellationToken()
    expectTrue(cancelledToken.cancelBeforeExecution()); expectFalse(cancelledToken.beginExecution())

    print("CLUSTER committed queued tasks withdraw before launch and can reserve again")
    var queuedWithdrawn = false
    for _ in 0..<20 {
        let queuedOutput = config.workspace.appendingPathComponent("queued_withdrawn.txt")
        let before = FileManager.default.fileExists(atPath: queuedOutput.path) ? try Data(contentsOf: queuedOutput) : Data()
        task.id = UUID().uuidString.lowercased()
        task.command = NativeCommand(["/bin/bash", "-c", "/bin/sleep 0.3; printf x >> queued_withdrawn.txt"])
        reserve.clusterTask = task
        let held = try unwrap(checked(transport.request(reserve, node: node)).clusterReservation)
        commit.clusterTask = task; commit.reservationID = held.id; commit.operatorToken = tokenB
        expectEqual(try checked(worker.handle(commit)).clusterUpdate?.state, "queued")
        withdraw.executionID = task.id; withdraw.reservationID = held.id; withdraw.operatorToken = tokenB
        let response = try checked(worker.handle(withdraw))
        query.executionID = task.id
        let until = Date(timeIntervalSinceNow: 5)
        var result = try unwrap(checked(transport.request(query, node: node)).clusterUpdate)
        while ["queued", "withdrawing", "running"].contains(result.state), Date() < until {
            Thread.sleep(forTimeInterval: 0.01)
            result = try unwrap(checked(transport.request(query, node: node)).clusterUpdate)
        }
        if response.clusterUpdate?.state == "withdrawing" {
            expectEqual(result.state, "withdrawn"); expectTrue(result.cleanupConfirmed == true)
            expectEqual(result.reservationID, held.id)
            let after = FileManager.default.fileExists(atPath: queuedOutput.path) ? try Data(contentsOf: queuedOutput) : Data()
            expectEqual(after, before)
            expectTrue(try checked(transport.request(withdraw, node: node)).confirmed == true)
            let next = try unwrap(checked(transport.request(reserve, node: node)).clusterReservation)
            expectNotEqual(next.id, held.id)
            commit.reservationID = next.id
            _ = try checked(transport.request(commit, node: node))
            expectFalse(try transport.request(withdraw, node: node).ok)
            let runningEnd = Date(timeIntervalSinceNow: 5)
            repeat {
                result = try unwrap(checked(transport.request(query, node: node)).clusterUpdate)
                if ["finished", "failed"].contains(result.state) { break }
                Thread.sleep(forTimeInterval: 0.01)
            } while Date() < runningEnd
            expectEqual(result.state, "finished"); expectEqual(result.reservationID, next.id)
            expectEqual(try Data(contentsOf: queuedOutput), before + Data("x".utf8))
            queuedWithdrawn = true; break
        }
        expectEqual(response.clusterUpdate?.state, "running"); expectEqual(result.state, "finished")
    }
    expectTrue(queuedWithdrawn)

    print("CLUSTER withdrawal leaves an already executing process intact")
    task.id = UUID().uuidString.lowercased()
    task.command = NativeCommand(["/bin/bash", "-c", "/bin/sleep 2; printf x >> retained_running.txt"])
    reserve.clusterTask = task
    let executing = try unwrap(checked(transport.request(reserve, node: node)).clusterReservation)
    commit.clusterTask = task; commit.reservationID = executing.id
    _ = try checked(transport.request(commit, node: node))
    query.executionID = task.id
    let executingDeadline = Date(timeIntervalSinceNow: 5)
    while try checked(transport.request(query, node: node)).clusterUpdate?.state == "queued", Date() < executingDeadline { Thread.sleep(forTimeInterval: 0.01) }
    withdraw.executionID = task.id; withdraw.reservationID = executing.id
    expectEqual(try checked(transport.request(withdraw, node: node)).clusterUpdate?.state, "running")
    let retainedDeadline = Date(timeIntervalSinceNow: 5)
    while try checked(transport.request(query, node: node)).clusterUpdate?.state == "running", Date() < retainedDeadline { Thread.sleep(forTimeInterval: 0.01) }
    expectEqual(try checked(transport.request(query, node: node)).clusterUpdate?.state, "finished")
    read.instanceID = dynamic.id; read.path = "retained_running.txt"
    expectEqual(try checked(local(read)).file?.data, Data("x".utf8))

    print("CLUSTER reservation interrupted before commit returns to the free source")
    let sourceBlock = try execute(first.nodeID == "manager" ? first : second, "/bin/sleep 4")
    let sourceBusy = Date(timeIntervalSinceNow: 3)
    while manager.status.executionCounts.serialRunning != 1 && Date() < sourceBusy { Thread.sleep(forTimeInterval: 0.03) }
    let reservationDisconnected = DispatchSemaphore(value: 0)
    transport.afterReply = { input, reply in
        if input.operation == "cluster-reserve", reply.clusterReservation != nil {
            transport.afterReply = nil
            server.requestStop(); serverDone.wait(); reservationDisconnected.signal()
        }
    }
    let returning = try execute(dynamic, "printf x >> returned.txt")
    guard reservationDisconnected.wait(timeout: .now() + 10) == .success else { throw SandboxError("relay was not disconnected after reservation") }
    _ = try wait(sourceBlock, owner: "manager")
    var occupyWorker = NativeControlRequest("exec"); occupyWorker.instanceID = remoteInstance.id; occupyWorker.operatorToken = tokenB
    occupyWorker.command = NativeCommand(["/bin/sleep", "8"])
    let workerBlock = try unwrap(checked(worker.handle(occupyWorker)).execution).id
    Thread.sleep(forTimeInterval: 0.2)
    server = try startServer()
    expectEqual(try wait(returning, owner: "manager", timeout: 15).state, "succeeded")
    read.instanceID = dynamic.id; read.path = "returned.txt"
    expectEqual(try checked(local(read)).file?.data, Data("x".utf8))
    expectFalse(try state(workerBlock, owner: "worker").isTerminal)
    _ = try wait(workerBlock, owner: "worker")
    expectNil(manager.status.recoveryReason); expectNil(worker.status.recoveryReason)

    print("CLUSTER scheduling pools and bidirectional node opt-out")
    func configurePools(_ localPool: String, _ remotePool: String, localEnabled: Bool = true, remoteEnabled: Bool = true) throws {
        controller.close()
        var peer = node; peer.schedulingPool = remotePool; peer.crossNodeSchedulingEnabled = remoteEnabled
        var configuration = ClusterConfiguration(localNodeID: "manager", sharedRoot: shared.path, nodes: [peer])
        configuration.schedulingPool = localPool; configuration.crossNodeSchedulingEnabled = localEnabled
        try configuration.validate()
        controller = try ClusterController(configuration: configuration, directory: output, transport: transport, local: local)
    }
    let ordinaryA = first.nodeID == "manager" ? first : second
    let ordinaryB = first.nodeID == "worker" ? first : second
    func staysLocal(_ instance: NativeInstanceRecord, blocker: NativeInstanceRecord, owner: String) throws {
        let blocked = try execute(blocker, "/bin/sleep 3")
        let host = owner == "manager" ? manager : worker
        let busy = Date(timeIntervalSinceNow: 3)
        while host.status.executionCounts.serialRunning != 1 && Date() < busy { Thread.sleep(forTimeInterval: 0.02) }
        let waiting = try execute(instance, "printf pool-local")
        Thread.sleep(forTimeInterval: 1.2)
        expectEqual(try state(waiting, owner: owner).state, "queued")
        let snapshot = controller.refresh()
        expectNil(ClusterPlacement.serialTarget(nodes: snapshot, source: owner))
        expectNil(ClusterPlacement.pendingTarget(nodes: snapshot, source: owner))
        _ = try wait(blocked, owner: owner)
        expectEqual(try wait(waiting, owner: owner).result?.stdout, Data("pool-local".utf8))
    }
    try configurePools("M3 Max", "M2 Pro")
    try staysLocal(dynamic, blocker: ordinaryA, owner: "manager")
    try staysLocal(remoteInstance, blocker: ordinaryB, owner: "worker")
    try configurePools("M3 Max", "M3 Max", localEnabled: false)
    try staysLocal(dynamic, blocker: ordinaryA, owner: "manager")
    try staysLocal(remoteInstance, blocker: ordinaryB, owner: "worker")
    try configurePools("M3 Max", "M3 Max", remoteEnabled: false)
    try staysLocal(dynamic, blocker: ordinaryA, owner: "manager")
    try staysLocal(remoteInstance, blocker: ordinaryB, owner: "worker")
    try configurePools("M3 Max", "M3 Max")
    for (instance, blocker, owner) in [(dynamic, ordinaryA, "manager"), (remoteInstance, ordinaryB, "worker")] {
        let holding = try execute(blocker, "/bin/sleep 5")
        let host = owner == "manager" ? manager : worker
        let busy = Date(timeIntervalSinceNow: 3)
        while host.status.executionCounts.serialRunning != 1 && Date() < busy { Thread.sleep(forTimeInterval: 0.02) }
        let moving = try execute(instance, "printf same-pool")
        expectEqual(try wait(moving, owner: owner).result?.stdout, Data("same-pool".utf8))
        expectFalse(try state(holding, owner: owner).isTerminal)
        _ = try wait(holding, owner: owner)
    }

    print("CLUSTER pool-scoped creation and validation")
    try configurePools("M3 Max", "M2 Pro", remoteEnabled: false)
    var pooled = NativeControlRequest("create"); pooled.count = 2; pooled.schedulingPool = "M2 Pro"
    let members = try unwrap(controller.handle(pooled)).instances ?? []
    expectEqual(members.count, 2)
    expectTrue(members.allSatisfy { $0.nodeID == "worker" })
    for instance in members { ids.append((instance.id, "worker")) }
    pooled.nodeID = "manager"
    expectThrows(try controller.handle(pooled))
    pooled.nodeID = nil; pooled.schedulingPool = "missing"
    expectThrows(try controller.handle(pooled))
    let stoppedSnapshot = controller.refresh()
    expectEqual(stoppedSnapshot.first { $0.id == "manager" }?.pool, "M3 Max")
    expectEqual(stoppedSnapshot.first { $0.id == "worker" }?.permitsCrossNodeScheduling, false)
    expectEqual(ClusterPlacement.pendingTarget(nodes: stoppedSnapshot, source: "worker"), "worker")
    for name in ["", " leading", "trailing ", "bad\npool", String(repeating: "a", count: 65)] {
        expectThrows(try ClusterConfiguration.validatePool(name))
    }
    try ClusterConfiguration.validatePool("高性能 M3 Max")

    print("CLUSTER restored reservation obeys the current scheduling pool")
    try configurePools("M3 Max", "M3 Max")
    let poolBlock = try execute(ordinaryA, "/bin/sleep 4")
    let poolBusy = Date(timeIntervalSinceNow: 3)
    while manager.status.executionCounts.serialRunning != 1 && Date() < poolBusy { Thread.sleep(forTimeInterval: 0.02) }
    let poolReserved = DispatchSemaphore(value: 0)
    var reservedTaskID: String?
    transport.afterReply = { input, reply in
        if input.operation == "cluster-reserve", let reservation = reply.clusterReservation {
            reservedTaskID = reservation.taskID
            transport.afterReply = nil
            server.requestStop(); serverDone.wait(); poolReserved.signal()
        }
    }
    let poolReturning = try execute(dynamic, "printf x >> pool_returned.txt")
    guard poolReserved.wait(timeout: .now() + 10) == .success else { throw SandboxError("pool test did not obtain a real reservation") }
    try configurePools("M3 Max", "M2 Pro")
    server = try startServer()
    _ = try wait(poolBlock, owner: "manager")
    expectEqual(try wait(poolReturning, owner: "manager", timeout: 15).state, "succeeded")
    read.instanceID = dynamic.id; read.path = "pool_returned.txt"
    expectEqual(try checked(local(read)).file?.data, Data("x".utf8))
    let remoteRecord = output.appendingPathComponent("worker/cluster_jobs/\(try unwrap(reservedTaskID)).json")
    if FileManager.default.fileExists(atPath: remoteRecord.path) {
        expectEqual(try SafeFiles.read(ClusterTaskUpdate.self, from: remoteRecord).state, "withdrawn")
    }
    expectNil(manager.status.recoveryReason); expectNil(worker.status.recoveryReason)

    print("CLUSTER receiving nodes enforce their local pool restrictions")
    for enabled in [false, true] {
        let name = enabled ? "pool_restricted" : "cross_disabled"
        var rules = ClusterConfiguration(localNodeID: name, sharedRoot: shared.path, nodes: [])
        rules.schedulingPool = "M2 Pro"; rules.crossNodeSchedulingEnabled = enabled
        let file = output.appendingPathComponent(name + ".json")
        try SafeFiles.write(rules, to: file)
        let directory = output.appendingPathComponent(name)
        let receiving = try NativeManager(directory: directory, binDirectory: bin, clusterURL: file,
            coordinationDirectory: output.appendingPathComponent(name + "_coord"))
        defer { receiving.shutdown() }
        let token = try NativeControlClient.operatorToken(stateDirectory: directory)
        var foreign = ClusterTask(instanceID: dynamic.id, workspace: try unwrap(dynamic.sharedWorkspace),
            command: NativeCommand(["/bin/echo", "pool-receiver"]), environment: [:], networkClient: false, taskPolicy: TaskPolicy())
        foreign.schedulingPool = "M3 Max"
        var request = NativeControlRequest("cluster-reserve"); request.operatorToken = token; request.clusterTask = foreign
        expectFalse(receiving.handle(request).ok)
        foreign.schedulingPool = "M2 Pro"; request.clusterTask = foreign
        let response = receiving.handle(request)
        if enabled {
            expectTrue(response.ok)
            let reservation = try unwrap(response.clusterReservation)
            request.operation = "cluster-release"; request.reservationID = reservation.id
            expectTrue(receiving.handle(request).ok)
        } else { expectFalse(response.ok) }
        expectEqual(receiving.status.activeInstances, 0)
        expectNil(receiving.status.recoveryReason)
    }

    print("CLUSTER durable claims survive restart until explicit recovery")
    let journal = output.appendingPathComponent("claim_journal")
    let queue = try ClusterTaskQueue(directory: journal)
    let token = CancellationToken()
    let delegation = queue.add(task, cancellation: token)
    expectTrue(try queue.claim(task.id)); expectFalse(delegation.startLocal())
    expectFalse(try queue.claim(task.id))
    queue.remove(task.id)
    let recovered = try ClusterTaskQueue(directory: journal)
    expectTrue(try recovered.hasUnfinishedClaims)
    try recovered.archiveClaims(to: output.appendingPathComponent("claim_recovery"))
    expectFalse(try recovered.hasUnfinishedClaims)

    print("CLUSTER configured NativeManager routes public operations")
    controller.close()
    let clusterURL = output.appendingPathComponent("cluster_config.json")
    try SafeFiles.write(ClusterConfiguration(localNodeID: "control", sharedRoot: shared.path, nodes: [node]), to: clusterURL)
    let controlDirectory = output.appendingPathComponent("control")
    let control = try NativeManager(directory: controlDirectory, binDirectory: bin, taskPolicyURL: policyURL,
        clusterURL: clusterURL, clusterTransport: transport, coordinationDirectory: output.appendingPathComponent("coordination_control"))
    defer { control.shutdown() }
    let controlToken = try NativeControlClient.operatorToken(stateDirectory: controlDirectory)
    func controlled(_ input: NativeControlRequest) throws -> NativeControlReply {
        var request = input; request.operatorToken = request.handle == nil ? controlToken : nil
        return try checked(control.handle(request))
    }
    var creation = NativeControlRequest("create"); creation.count = 1; creation.nodeID = "worker"; creation.dynamicScheduling = true
    let routed = try unwrap(controlled(creation).instances?.first)
    ids.append((routed.id, "worker"))
    expectEqual(routed.nodeID, "worker"); expectTrue(routed.dynamicScheduling == true)
    var routedWrite = NativeControlRequest("write"); routedWrite.instanceID = routed.id
    routedWrite.file = WorkspaceFile(path: "routed.txt", data: Data("routed".utf8))
    _ = try controlled(routedWrite)
    var routedExec = NativeControlRequest("exec"); routedExec.instanceID = routed.id
    routedExec.command = NativeCommand(["/bin/cat", "routed.txt"])
    let routedJob = try unwrap(controlled(routedExec).execution).id
    var routedQuery = NativeControlRequest("execution"); routedQuery.executionID = routedJob
    let routedDeadline = Date(timeIntervalSinceNow: 10)
    var routedResult = try unwrap(controlled(routedQuery).execution)
    while !routedResult.isTerminal && Date() < routedDeadline {
        Thread.sleep(forTimeInterval: 0.03); routedResult = try unwrap(controlled(routedQuery).execution)
    }
    expectEqual(routedResult.state, "succeeded")
    expectEqual(routedResult.result?.stdout, Data("routed".utf8))
    var routedGrant = NativeControlRequest("grant"); routedGrant.instanceID = routed.id; routedGrant.operations = [.read]
    let scoped = try unwrap(controlled(routedGrant).handle)
    var routedRead = NativeControlRequest("read"); routedRead.instanceID = routed.id; routedRead.path = "routed.txt"; routedRead.handle = scoped
    expectEqual(try controlled(routedRead).file?.data, Data("routed".utf8))
    routedRead.operation = "write"; routedRead.file = WorkspaceFile(path: "denied.txt", data: Data())
    expectThrows(try controlled(routedRead))
    var routedStop = NativeControlRequest("stop"); routedStop.instanceID = routed.id
    _ = try controlled(routedStop)
    routedStop.operation = "delete"; routedStop.confirmed = true
    _ = try controlled(routedStop)
    ids.removeAll { $0.0 == routed.id }
    expectFalse(try controlled(NativeControlRequest("list")).instances?.contains { $0.id == routed.id } == true)
    try SafeFiles.write(["assertionFailures": assertionFailures.joined(separator: "\n"), "manager": manager.status.host.hostname,
        "verification": "two real local managers, public CLI relay processes, App Sandbox Hosts and independent scheduler leases; SSH/SMB not exercised"],
        to: output.appendingPathComponent("report.json"))
    guard assertionFailures.isEmpty else { throw SandboxError("cluster tests failed") }
}
