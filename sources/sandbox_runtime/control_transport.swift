import Foundation
import Darwin
import SandboxCore

private enum NativeSocket {
    static func address<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(NativePaths.socket.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SandboxError("native socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
}

public enum NativeControlClient {
    public static func relay(_ request: NativeControlRequest, channel peer: FramedChannel) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SandboxError("cannot create relay socket") }
        defer { close(fd) }; NativeSocket.configure(fd)
        try NativeSocket.address { guard connect(fd, $0, $1) == 0 else { throw SandboxError("cannot connect relay manager") } }
        let local = try FramedChannel(input: fd, output: fd)
        try local.send(request)
        guard let ready = try local.receive(NativeControlReply.self, timeout: request.responseTimeout) else { throw SandboxError("relay manager disconnected") }
        try peer.send(ready)
        guard ready.ok, ["download", "upload", "test-package"].contains(request.operation) else { return }
        if request.operation == "download" { try local.forwardFile(to: peer) }
        else {
            try peer.forwardFile(to: local)
            guard let completed = try local.receive(NativeControlReply.self, timeout: .infinity) else { throw SandboxError("relay transfer disconnected") }
            try peer.send(completed)
        }
    }
    public static func request(_ request: NativeControlRequest, timeout: Double? = nil) throws -> NativeControlReply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SandboxError("cannot create native control socket") }
        defer { close(fd) }
        NativeSocket.configure(fd)
        try NativeSocket.address {
            guard connect(fd, $0, $1) == 0 else { throw SandboxError("cannot connect native manager: \(String(cString: strerror(errno)))") }
        }
        let channel = try FramedChannel(input: fd, output: fd)
        try channel.send(request)
        guard let reply = try channel.receive(NativeControlReply.self, timeout: timeout ?? request.responseTimeout), reply.requestID == request.requestID else {
            throw SandboxError("native manager disconnected or response identity mismatched")
        }
        guard reply.ok else { throw SandboxError(reply.error ?? "native request rejected", code: reply.errorCode) }
        return reply
    }
    public static func transfer(_ request: NativeControlRequest, archive: URL) throws -> NativeControlReply {
        guard ["download", "upload", "test-package"].contains(request.operation) else { throw SandboxError("invalid transfer operation") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SandboxError("cannot create native transfer socket") }
        defer { close(fd) }; NativeSocket.configure(fd)
        try NativeSocket.address {
            guard connect(fd, $0, $1) == 0 else { throw SandboxError("cannot connect native manager") }
        }
        let channel = try FramedChannel(input: fd, output: fd)
        try channel.send(request)
        func reply() throws -> NativeControlReply {
            guard let value = try channel.receive(NativeControlReply.self, timeout: .infinity), value.requestID == request.requestID else {
                throw SandboxError("manager transfer disconnected or reply mismatch")
            }
            guard value.ok else { throw SandboxError(value.error ?? "transfer rejected") }; return value
        }
        let ready = try reply()
        if request.operation == "download" {
            if let failure = try channel.receiveFile(to: archive) { throw failure }
            try WorkspaceArchive.read(archive); return ready
        }
        let failure = try channel.sendFile(archive)
        let completed = try reply()
        if let failure { throw failure }; return completed
    }
    public static func operatorToken(stateDirectory: URL) throws -> String {
        let data = try SafeFiles.readRegular(stateDirectory.appendingPathComponent("operator_token"), limit: 256)
        let token = String(decoding: data, as: UTF8.self)
        guard token.count == 64, token.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw SandboxError("invalid operator token") }
        return token
    }
}

/// Framed local IPC; peer UID is necessary but NEVER substitutes for the bearer
/// capability checked by the handler. No automatic replay after disconnect.
public final class NativeControlServer {
    private let handler: (NativeControlRequest) -> NativeControlReply
    private let transfer: ((NativeControlRequest, FramedChannel) throws -> Void)?
    private let lock = NSLock()
    private var stopped = false
    private let connections = DispatchGroup()
    private let capacity = DispatchSemaphore(value: 32)
    public init(transfer: ((NativeControlRequest, FramedChannel) throws -> Void)? = nil,
                handler: @escaping (NativeControlRequest) -> NativeControlReply) { self.handler = handler; self.transfer = transfer }
    public func requestStop() { lock.lock(); stopped = true; lock.unlock() }
    public func serve(onReady: () -> Void) throws {
        let path = NativePaths.socket.path
        var st = stat()
        if lstat(path, &st) == 0 {
            guard st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0 else {
                throw SandboxError("unsafe native socket path")
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SandboxError("cannot create native listener") }
        NativeSocket.configure(fd)
        var bound = false
        defer { close(fd); connections.wait(); if bound { _ = unlink(path) } }
        try NativeSocket.address { guard bind(fd, $0, $1) == 0 else { throw SandboxError("native bind failed") } }
        bound = true
        guard chmod(path, 0o600) == 0, listen(fd, SOMAXCONN) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw SandboxError("native listen failed") }
        onReady()
        while true {
            lock.lock(); let stop = stopped; lock.unlock()
            if stop { break }
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 100)
            if ready < 0 && errno != EINTR { throw SandboxError("native listener poll failed") }
            if ready <= 0 { continue }
            // 处理容量耗尽时，让连接保留在系统等待队列中，避免接受后直接断开。
            guard capacity.wait(timeout: .now() + .milliseconds(100)) == .success else { continue }
            let client = accept(fd, nil, nil)
            if client < 0 { capacity.signal(); continue }
            NativeSocket.configure(client)
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client); capacity.signal(); continue
            }
            connections.enter()
            DispatchQueue.global().async { [self] in
                defer { close(client); capacity.signal(); connections.leave() }
                do {
                    let channel = try FramedChannel(input: client, output: client)
                    guard let request = try channel.receive(NativeControlRequest.self, timeout: 5) else { return }
                    if ["download", "upload", "test-package"].contains(request.operation), let transfer { try transfer(request, channel) }
                    else { try channel.send(handler(request)) }
                } catch { /* Malformed/oversized requests get disconnected, never executed. */ }
            }
        }
    }
}

public final class RemoteSandboxSession: SandboxSession {
    public let id: String
    private let handle: SandboxHandle
    private let closeLock = NSLock()
    private var closed = false
    public init(handle: SandboxHandle) { self.handle = handle; id = handle.instanceID }
    private func request(_ operation: String, configure: (inout NativeControlRequest) -> Void = { _ in }) throws -> NativeControlReply {
        var request = NativeControlRequest(operation); request.handle = handle; request.instanceID = id
        configure(&request); return try NativeControlClient.request(request)
    }
    public func download(to url: URL, path: String?) throws {
        var r = NativeControlRequest("download"); r.handle = handle; r.instanceID = id; r.path = path
        _ = try NativeControlClient.transfer(r, archive: url)
    }
    public func upload(from url: URL) throws {
        var r = NativeControlRequest("upload"); r.handle = handle; r.instanceID = id
        _ = try NativeControlClient.transfer(r, archive: url)
    }
    public func read(_ path: String) throws -> WorkspaceFile {
        try WorkspaceArchive.temporary { url in
            try download(to: url, path: path)
            guard let file = try WorkspaceArchive.collect(url).first else { throw SandboxError("missing file") }; return file
        }
    }
    public func write(_ file: WorkspaceFile) throws {
        try WorkspaceArchive.temporary { url in
            try WorkspaceArchive.write(url) { try $0.append(file) }; try upload(from: url)
        }
    }
    public func listDirectory(_ path: String, after: String?) throws -> WorkspaceDirectory {
        guard let directory = try request("ls", configure: { $0.path = path; $0.after = after }).directory else { throw SandboxError("missing directory listing") }
        return directory
    }
    public func export() throws -> [WorkspaceFile] {
        try WorkspaceArchive.temporary { url in
            try download(to: url, path: nil); return try WorkspaceArchive.collect(url)
        }
    }
    public func execute(_ command: NativeCommand) throws -> NativeResult { try execute(command, cancellation: CancellationToken()) }
    public func execute(_ command: NativeCommand, cancellation: CancellationToken) throws -> NativeResult {
        guard !cancellation.isCancelled else { throw SandboxError("cancelled before submission") }
        guard let submitted = try request("exec", configure: { $0.command = command }).execution else { throw SandboxError("missing execution ID") }
        while true {
            if cancellation.isCancelled { _ = try request("cancel", configure: { $0.executionID = submitted.id }) }
            guard let record = try request("execution", configure: { $0.executionID = submitted.id }).execution else { throw SandboxError("missing execution record") }
            if record.isTerminal {
                if record.error == nil, let result = record.result, result.outcome.reason == .exited { return result }
                throw SandboxError(record.error ?? "execution \(record.state)")
            }
            usleep(50_000)
        }
    }
    public func close() throws {
        closeLock.lock(); defer { closeLock.unlock() }
        if closed { return }; _ = try request("stop"); closed = true
    }
}
