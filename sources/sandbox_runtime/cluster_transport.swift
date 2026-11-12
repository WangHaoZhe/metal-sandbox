import Foundation
import Darwin
import SandboxCore

public protocol ClusterTransport: AnyObject {
    func request(_ request: NativeControlRequest, node: ClusterNode) throws -> NativeControlReply
    func transfer(_ request: NativeControlRequest, node: ClusterNode, channel: FramedChannel) throws
    func forward(node: ClusterNode, sourcePort: Int, listenPort: Int) throws -> ClusterPortForward
}

public protocol ClusterPortForward: AnyObject {
    var isRunning: Bool { get }
    @discardableResult func close() -> Bool
}

extension ClusterTransport {
    public func forward(node: ClusterNode, sourcePort: Int, listenPort: Int) throws -> ClusterPortForward {
        throw SandboxError("this cluster transport does not support loopback forwarding")
    }
}

/// The relay uses the same bounded protocol as local control; no task shell runs over SSH.
public final class SSHClusterTransport: ClusterTransport {
    public init() {}
    public static func connectionArguments(_ node: ClusterNode) throws -> [String] {
        try node.validate()
        var args = ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3"]
        if let port = node.sshPort { args += ["-p", String(port)] }
        if let identity = node.identityFile { args += ["-F", "/dev/null", "-i", identity, "-o", "IdentitiesOnly=yes"] }
        if let knownHosts = node.knownHostsFile { args += ["-o", "UserKnownHostsFile=\"\(knownHosts)\""] }
        if let alias = node.hostKeyAlias { args += ["-o", "HostKeyAlias=" + alias] }
        return args
    }
    public static func arguments(_ node: ClusterNode) throws -> [String] {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return try connectionArguments(node) + ["--", node.sshDestination,
            [node.cliPath, "--state-dir", node.stateDirectory, "cluster-relay"].map(quote).joined(separator: " ")]
    }
    public func request(_ request: NativeControlRequest, node: ClusterNode) throws -> NativeControlReply {
        try ClusterRelayConnection.withConnection(argv: Self.arguments(node)) { try $0.request(request) }
    }
    public func transfer(_ request: NativeControlRequest, node: ClusterNode, channel: FramedChannel) throws {
        try ClusterRelayConnection.withConnection(argv: Self.arguments(node)) { try $0.transfer(request, peer: channel) }
    }
    public func forward(node: ClusterNode, sourcePort: Int, listenPort: Int) throws -> ClusterPortForward {
        try LoopbackPort.validate(sourcePort); try LoopbackPort.validate(listenPort)
        var argv = try Self.arguments(node)
        argv.insert(contentsOf: ["-S", "none", "-o", "ControlMaster=no", "-o", "ForkAfterAuthentication=no",
                                "-o", "ExitOnForwardFailure=yes", "-R", "127.0.0.1:\(listenPort):127.0.0.1:\(sourcePort)"], at: 1)
        let connection = try ClusterRelayConnection(argv: argv, environment: nil)
        do {
            var request = NativeControlRequest("port-forward-probe"); request.forwardPort = listenPort
            let reply = try connection.request(request)
            guard reply.ok, reply.confirmed == true else { throw SandboxError(reply.error ?? "loopback forwarding was not confirmed") }
            return connection
        } catch {
            let failure = connection.failure(error)
            connection.close(); throw failure
        }
    }
}

public final class ClusterRelayConnection: ClusterPortForward {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let channel: FramedChannel
    private let diagnosticsLock = NSLock()
    private var diagnostics = Data()
    private let exitSignal = DispatchGroup()
    private let closeLock = NSLock()
    private var closed = false
    public init(argv: [String], environment: [String: String]?) throws {
        guard let program = argv.first, program.hasPrefix("/") else { throw SandboxError("relay executable must be absolute") }
        channel = try FramedChannel(input: output.fileHandleForReading.fileDescriptor, output: input.fileHandleForWriting.fileDescriptor)
        process.executableURL = URL(fileURLWithPath: program); process.arguments = Array(argv.dropFirst())
        if let environment { process.environment = environment }
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.diagnosticsLock.lock()
            if let self, self.diagnostics.count < 8192 { self.diagnostics.append(data.prefix(8192 - self.diagnostics.count)) }
            self?.diagnosticsLock.unlock()
        }
        exitSignal.enter()
        process.terminationHandler = { [exitSignal] _ in exitSignal.leave() }
        do { try process.run() }
        catch { exitSignal.leave(); throw error }
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close(); try errors.fileHandleForWriting.close()
    }
    public static func withConnection<T>(argv: [String], environment: [String: String]? = nil, _ body: (ClusterRelayConnection) throws -> T) throws -> T {
        let connection = try ClusterRelayConnection(argv: argv, environment: environment)
        defer { connection.close() }
        do { return try body(connection) }
        catch { throw connection.failure(error) }
    }
    fileprivate func failure(_ error: Error) -> SandboxError {
        diagnosticsLock.lock(); defer { diagnosticsLock.unlock() }
        let detail = String(decoding: diagnostics, as: UTF8.self)
        return SandboxError("cluster relay failed: \(error)\(detail.isEmpty ? "" : "; " + detail)")
    }
    private func send(_ request: NativeControlRequest) throws {
        var request = request; request.operatorToken = nil; request.localOnly = true
        try channel.send(request)
    }
    private func reply(_ request: NativeControlRequest) throws -> NativeControlReply {
        guard let reply = try channel.receive(NativeControlReply.self, timeout: request.responseTimeout), reply.requestID == request.requestID else {
            throw SandboxError("cluster reply identity mismatch or disconnect")
        }
        return reply
    }
    public func request(_ request: NativeControlRequest) throws -> NativeControlReply {
        try send(request); return try reply(request)
    }
    public func transfer(_ request: NativeControlRequest, peer: FramedChannel) throws {
        try send(request)
        let ready = try reply(request); try peer.send(ready)
        guard ready.ok else { return }
        if request.operation == "download" { try channel.forwardFile(to: peer) }
        else { try peer.forwardFile(to: channel); try peer.send(reply(request)) }
    }
    public var isRunning: Bool { process.isRunning }
    @discardableResult public func close() -> Bool {
        closeLock.lock(); defer { closeLock.unlock() }
        guard !closed else { return true }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        if exitSignal.wait(timeout: .now() + 2) != .success, process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = exitSignal.wait(timeout: .now() + 5)
        }
        if process.isRunning {
            FileHandle.standardError.write(Data("SSH relay process termination could not be confirmed\n".utf8))
            return false
        }
        closed = true
        errors.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        return true
    }
}

public enum LoopbackPort {
    public static func validate(_ port: Int) throws {
        guard (1024...65535).contains(port) else { throw SandboxError("loopback port must be in 1024...65535") }
    }
    public static func check(_ port: Int) throws {
        try validate(port)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SandboxError("cannot create loopback probe") }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw SandboxError("cannot configure loopback probe") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 { return }
        guard errno == EINPROGRESS else { throw SandboxError("loopback service is unavailable on port \(port)") }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
        guard poll(&descriptor, 1, 1000) > 0,
              getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
            throw SandboxError("loopback service is unavailable on port \(port)")
        }
    }
}
