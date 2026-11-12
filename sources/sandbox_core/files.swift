import Foundation
import Darwin

public enum Paths {
    public static var defaultState: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MetalSandbox")
    }
    public static var coordination: URL {
        if let directory = ProcessInfo.processInfo.environment["METAL_SANDBOX_COORDINATION_DIR"] {
            return URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: "/private/tmp/metal-sandbox-\(getuid())", isDirectory: true)
    }
}

public enum SafeFiles {
    public static func secureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw SandboxError("directory must be real and owned by this UID: \(url.path)")
        }
        guard chmod(url.path, 0o700) == 0 else { throw SandboxError("cannot restrict directory: \(url.path)") }
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try writeData(JSON.data(value, pretty: true), to: url)
    }

    public static func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw SandboxError("cannot set file permissions: \(url.path)") }
    }

    public static func readRegular(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SandboxError("cannot open regular file \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size >= 0, st.st_size <= limit else {
            throw SandboxError("not a regular file, or exceeds \(limit) bytes: \(url.path)")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(65536, max(1, limit)))
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw SandboxError("read failed: \(url.path)")
            }
            guard result.count + count <= limit else { throw SandboxError("file grew beyond limit: \(url.path)") }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL, limit: Int = 2 * 1024 * 1024) throws -> T {
        try JSON.decoder().decode(type, from: readRegular(url, limit: limit))
    }
}

public final class FileLease {
    private var fd: Int32 = -1
    public init(_ path: URL) throws {
        fd = open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SandboxError("cannot open lease: \(path.path)") }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); fd = -1
            throw SandboxError("another daemon owns this lease, or lease is unsafe: \(path.path)")
        }
        _ = fchmod(fd, 0o600)
    }
    deinit { if fd >= 0 { _ = flock(fd, LOCK_UN); close(fd) } }
}

