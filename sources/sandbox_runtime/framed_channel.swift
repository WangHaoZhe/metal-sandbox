import Foundation
import Darwin
import SandboxCore

/// Length-prefixed, bounded JSON. The same absolute monotonic deadline applies
/// to the header and body; a peer cannot keep a request alive one byte at a time.
public final class FramedChannel {
    public static let messageLimit = 16 * 1024 * 1024
    private let input: Int32
    private let output: Int32
    private let sendLock = NSLock()
    public init(input: Int32, output: Int32) throws {
        self.input = input; self.output = output
        for fd in Set([input, output]) {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw SandboxError("cannot configure private pipe") }
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }
    }
    private func deadline(_ seconds: Double) -> UInt64 {
        MonotonicDeadline.after(seconds)
    }
    private func ready(_ fd: Int32, events: Int16, until end: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < end else { throw SandboxError("private IPC deadline exceeded") }
            let ms = Int32(min(1000, max(1, (end - now) / 1_000_000)))
            var item = pollfd(fd: fd, events: events, revents: 0)
            let n = poll(&item, 1, ms)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw SandboxError("private IPC poll failed") }
            if n > 0 { return }
        }
    }
    private func readBytes(_ count: Int, until end: UInt64, allowEOF: Bool = false) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try ready(input, events: Int16(POLLIN), until: end)
            let n = data.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress!.advanced(by: offset), count - offset) }
            if n < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            if n == 0, offset == 0, allowEOF { return nil }
            guard n > 0 else { throw SandboxError("private IPC closed mid-message") }
            offset += n
        }
        return data
    }
    public func receive<T: Decodable>(_ type: T.Type, timeout: Double = 30) throws -> T? {
        try autoreleasepool {
        let end = deadline(timeout)
        guard let header = try readBytes(4, until: end, allowEOF: true) else { return nil }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= Self.messageLimit else { throw SandboxError("invalid private IPC frame length") }
        return try JSON.decoder().decode(type, from: readBytes(length, until: end)!)
        }
    }
    public func send<T: Encodable>(_ value: T, timeout: Double = 10) throws {
        try autoreleasepool {
        sendLock.lock(); defer { sendLock.unlock() }
        let body = try JSON.data(value)
        guard body.count <= Self.messageLimit else { throw SandboxError("private IPC message too large") }
        var length = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        let end = deadline(timeout)
        var offset = 0
        while offset < frame.count {
            try ready(output, events: Int16(POLLOUT), until: end)
            let n = frame.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), frame.count - offset) }
            if n < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard n > 0 else { throw SandboxError("private IPC write failed: \(String(cString: strerror(errno))) (errno \(errno))") }
            offset += n
        }
        }
    }

    private struct FileBlock: Codable { var data: Data?; var error: String? }
    public func forwardFile(to destination: FramedChannel) throws {
        while true {
            guard let block = try receive(FileBlock.self, timeout: 120) else { throw SandboxError("relay file disconnected") }
            if let data = block.data {
                guard !data.isEmpty, data.count <= WorkspaceArchive.chunkSize, block.error == nil else { throw SandboxError("invalid relay file block") }
            }
            try destination.send(block)
            if block.data == nil { return }
        }
    }
    /// A nil block terminates the transfer. Source/destination errors are returned
    /// only after that marker; transport errors throw and require disconnection.
    public func sendFile(_ url: URL) throws -> Error? {
        let input: FileHandle
        do { input = try WorkspaceArchive.openRegular(url) }
        catch { try send(FileBlock(error: String(describing: error))); return error }
        defer { try? input.close() }
        while true {
            let data: Data
            do { data = try autoreleasepool { try input.read(upToCount: WorkspaceArchive.chunkSize) ?? Data() } }
            catch { try send(FileBlock(error: String(describing: error))); return error }
            if data.isEmpty { try send(FileBlock()); return nil }
            try send(FileBlock(data: data))
        }
    }
    public func receiveFile(to url: URL, validate: ((URL) throws -> Void)? = nil, didWrite: ((Data) -> Void)? = nil) throws -> Error? {
        var failure: Error?, started = false
        func receive(_ output: FileHandle?) throws {
            started = true
            while true {
                guard let block = try self.receive(FileBlock.self, timeout: 120) else { throw SandboxError("file transfer disconnected") }
                guard let data = block.data else {
                    if let error = block.error { failure = SandboxError(error) }; return
                }
                guard !data.isEmpty, data.count <= WorkspaceArchive.chunkSize, block.error == nil else { throw SandboxError("invalid file transfer chunk") }
                if failure == nil {
                    do { try output?.write(contentsOf: data); didWrite?(data) }
                    catch { failure = error } // Drain the stream, retaining the previous file.
                }
            }
        }
        var transportError: Error?
        do {
            try WorkspaceArchive.atomic(url, validate: validate) { output in
                do { try receive(output) } catch { transportError = error; throw error }
                if let failure { throw failure }
            }
        } catch {
            if let transportError { throw transportError }
            failure = error
            if !started { try receive(nil) }
        }
        return failure
    }
}
