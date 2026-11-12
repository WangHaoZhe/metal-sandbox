import Foundation
import Darwin
import SandboxCore
import SandboxRuntime
import SandboxManagement

func runLoopbackTests(port: Int) throws {
    try LoopbackPort.check(port)
    for invalid in [-1, 0, 22, 65536] {
        do { try LoopbackPort.validate(invalid); throw SandboxError("invalid port accepted") }
        catch let error as SandboxError where error.description.contains("1024...65535") {}
    }
    let registry = try LoopbackForwardRegistry(configuration: nil, transport: SSHClusterTransport(), lifetime: 0.4)
    defer { registry.shutdown() }
    let instance = "sbx-" + UUID().uuidString.lowercased(), id = UUID().uuidString.lowercased()
    let opened = try registry.open(id: id, instanceID: instance, owner: "local", port: port)
    guard opened.port == port, opened.readyNodeIDs == ["local"] else { throw SandboxError("incorrect local endpoint") }
    guard registry.prepare(instanceID: instance, ids: [id], nodeID: "local"),
          !registry.prepare(instanceID: "another-instance", ids: [id], nodeID: "local"),
          !registry.prepare(instanceID: instance, ids: [UUID().uuidString], nodeID: "local"),
          !registry.prepare(instanceID: instance, ids: [id], nodeID: "unknown") else {
        throw SandboxError("forward dependency identity validation failed")
    }
    let repeatOpen = try registry.open(id: id, instanceID: instance, owner: "local", port: port)
    guard repeatOpen.id == id else { throw SandboxError("idempotent open changed identity") }
    do {
        _ = try registry.open(id: UUID().uuidString, instanceID: "other", owner: "local", port: port)
        throw SandboxError("port collision accepted")
    } catch let error as SandboxError where error.description.contains("already has a lease") {}
    Thread.sleep(forTimeInterval: 0.2)
    let refreshed = try registry.status(id: id, instanceID: instance)
    guard refreshed.expiresAt > opened.expiresAt else { throw SandboxError("lease was not renewed") }
    Thread.sleep(forTimeInterval: 0.6)
    guard !registry.prepare(instanceID: instance, ids: [id], nodeID: "local") else { throw SandboxError("expired dependency was usable") }
    do { _ = try registry.status(id: id, instanceID: instance); throw SandboxError("expired lease revived") }
    catch let error as SandboxError where error.description.contains("expired") {}
    registry.close(id: id, instanceID: instance)
    registry.close(id: id, instanceID: instance)
    _ = try registry.open(id: UUID().uuidString, instanceID: instance, owner: "local", port: port)
    registry.close(instanceID: instance)
    print("PASS: real TCP endpoint, port validation, exclusive leases, identity, renewal, expiration, idempotent cleanup")
}

func runSSHForwardTest(node: URL, sourcePort: Int, listenPort: Int) throws {
    let node = try SafeFiles.read(ClusterNode.self, from: node)
    let ready = DispatchSemaphore(value: 0), lock = NSLock()
    var result: Result<ClusterPortForward, Error>?
    DispatchQueue(label: "forward-test-launch").async {
        let value = Result { try SSHClusterTransport().forward(node: node, sourcePort: sourcePort, listenPort: listenPort) }
        lock.lock(); result = value; lock.unlock(); ready.signal()
    }
    guard ready.wait(timeout: .now() + 20) == .success else { throw SandboxError("SSH forwarding startup timed out") }
    lock.lock(); let started = result; lock.unlock()
    guard let started else { throw SandboxError("missing forwarding startup result") }
    let connection = try started.get()
    defer { connection.close() }
    guard connection.isRunning else { throw SandboxError("SSH forwarding exited after startup") }
    print("READY"); fflush(stdout)
    while let _ = readLine() {
        guard connection.isRunning else { throw SandboxError("SSH forwarding connection was lost") }
        print("ALIVE"); fflush(stdout)
    }
}

private final class FakeForward: ClusterPortForward {
    var running = true
    var isRunning: Bool { running }
    func close() -> Bool { running = false; return true }
}

private final class FakeTransport: ClusterTransport {
    let lock = NSLock()
    var forwards: [FakeForward] = []
    var failures: [String: Int] = [:]
    var calls: [String: Int] = [:]
    func request(_ request: NativeControlRequest, node: ClusterNode) throws -> NativeControlReply {
        lock.lock(); defer { lock.unlock() }
        calls[request.operation, default: 0] += 1
        if failures[request.operation, default: 0] > 0 {
            failures[request.operation]! -= 1
            throw SandboxError("cluster relay failed: Connection reset by peer")
        }
        return NativeControlReply(requestID: request.requestID)
    }
    func transfer(_ request: NativeControlRequest, node: ClusterNode, channel: FramedChannel) throws {}
    func forward(node: ClusterNode, sourcePort: Int, listenPort: Int) throws -> ClusterPortForward {
        lock.lock(); defer { lock.unlock() }
        let forward = FakeForward(); forwards.append(forward); return forward
    }
}

private let workerNode = ClusterNode(id: "worker", sshDestination: "user@worker.local",
                                     cliPath: "/Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl",
                                     stateDirectory: "/Users/user/Library/Application Support/MetalSandbox/native")

private func loopbackListener() throws -> (Int32, Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SandboxError("cannot create test listener") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &length) == 0
        }
    }
    guard bound else { close(fd); throw SandboxError("cannot bind test listener") }
    return (fd, Int(UInt16(bigEndian: address.sin_port)))
}

func runLoopbackOwnerReconnectTest() throws {
    let (listener, port) = try loopbackListener()
    defer { close(listener) }
    let transport = FakeTransport()
    let configuration = ClusterConfiguration(localNodeID: "manager", nodes: [workerNode])
    let registry = try LoopbackForwardRegistry(configuration: configuration, transport: transport, lifetime: 30)
    defer { registry.shutdown() }
    let instance = "sbx-" + UUID().uuidString.lowercased(), id = UUID().uuidString.lowercased()
    let opened = try registry.open(id: id, instanceID: instance, owner: "worker", port: port)
    guard opened.readyNodeIDs.contains("worker"), transport.forwards.count == 1 else { throw SandboxError("owner forward not ready") }
    transport.forwards[0].running = false
    let lost = try registry.status(id: id, instanceID: instance)
    guard !lost.readyNodeIDs.contains("worker") else { throw SandboxError("lost owner forward reported ready") }
    let deadline = Date().addingTimeInterval(5)
    var info = lost
    while !info.readyNodeIDs.contains("worker") {
        guard Date() < deadline else { throw SandboxError("owner forward was not rebuilt") }
        Thread.sleep(forTimeInterval: 0.02)
        info = try registry.status(id: id, instanceID: instance)
    }
    guard info.id == id, transport.forwards.count == 2, info.nodeErrors["worker"] == nil else {
        throw SandboxError("owner forward was not rebuilt under the same lease")
    }
}

func runClusterRelayRetryTest() throws {
    let transport = FakeTransport()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-relay-\(UUID().uuidString.lowercased())")
    defer { try? FileManager.default.removeItem(at: root) }
    let instance = "sbx-" + UUID().uuidString.lowercased()
    try SafeFiles.secureDirectory(root.appendingPathComponent("cluster"))
    try SafeFiles.write([instance: "worker"], to: root.appendingPathComponent("cluster/instances.json"))
    let controller = try ClusterController(configuration: ClusterConfiguration(localNodeID: "manager", nodes: [workerNode]),
                                           directory: root, transport: transport) { NativeControlReply(requestID: $0.requestID) }
    defer { controller.close() }
    var inspect = NativeControlRequest("inspect"); inspect.instanceID = instance
    transport.lock.lock(); transport.failures["inspect"] = 2; transport.lock.unlock()
    _ = try controller.handle(inspect)
    var stop = NativeControlRequest("stop"); stop.instanceID = instance
    transport.lock.lock(); transport.failures["stop"] = 1; transport.lock.unlock()
    do { _ = try controller.handle(stop); throw SandboxError("mutating request was retried") }
    catch let error as SandboxError where error.description.contains("Connection reset") {}
    transport.lock.lock(); defer { transport.lock.unlock() }
    guard transport.calls["inspect"] == 3, transport.calls["stop"] == 1 else {
        throw SandboxError("unexpected relay attempts: \(transport.calls)")
    }
}
