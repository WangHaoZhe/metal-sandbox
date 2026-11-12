import Foundation
import CryptoKit
import ZIPFoundation
import Darwin
import SandboxCore

/// Disk-backed workspace transport. Only metadata and one chunk are in memory;
/// the chunk/header bounds are not file or snapshot size limits.
public enum WorkspaceArchive {
    public static let chunkSize = 256 * 1024
    public struct Entry: Codable {
        public var file: WorkspaceFile
        public var size: Int64
        public init(file: WorkspaceFile, size: Int64) { self.file = file; self.size = size }
        func validate() throws {
            try file.validate()
            guard file.data.isEmpty, size >= 0, file.linkTarget == nil || size == 0 else {
                throw SandboxError("invalid archive entry")
            }
        }
    }
    public struct Summary { public var files = 0; public var bytes: Int64 = 0 }

    public static func temporary<T>(directory: URL = FileManager.default.temporaryDirectory,
                                    _ body: (URL) throws -> T) throws -> T {
        let folder = directory.appendingPathComponent("workspace-transfer-" + UUID().uuidString.lowercased())
        try SafeFiles.secureDirectory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder.appendingPathComponent("workspace.zip"))
    }
    public static func openRegular(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SandboxError("cannot open regular file: \(url.path)") }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_size >= 0 else {
            close(fd); throw SandboxError("reject special file or hardlink: \(url.path)")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    /// Replace only after a complete write; failure retains the old destination.
    public static func atomic(_ url: URL, validate: ((URL) throws -> Void)? = nil, _ body: (FileHandle) throws -> Void) throws {
        let stage = url.deletingLastPathComponent().appendingPathComponent(".transfer-" + UUID().uuidString.lowercased())
        let fd = open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SandboxError("cannot stage transfer: \(url.path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlink(stage.path) }
        try body(handle)
        try handle.synchronize()
        try validate?(stage)
        guard rename(stage.path, url.path) == 0 else { throw SandboxError("cannot commit transfer: \(url.path)") }
    }
    public final class Writer {
        private let archive: ZIPFoundation.Archive
        private var paths = Set<String>()
        private var directories = Set<String>()
        public private(set) var summary = Summary()
        fileprivate init(_ url: URL) throws { archive = try ZIPFoundation.Archive(url: url, accessMode: .create) }
        public func append(_ entry: Entry, next: () throws -> Data) throws {
            try entry.validate()
            try WorkspaceArchive.checkDirectoryConflicts(entry.file.path, directories: directories)
            try WorkspaceArchive.register(entry, paths: &paths, summary: &summary)
            guard paths.count + directories.count <= ConfinedWorkspace.entryLimit else { throw SandboxError("archive entry limit exceeded") }
            let link = entry.file.linkTarget.map { Data($0.utf8) }
            var offset: Int64 = 0
            let size = link.map { Int64($0.count) } ?? entry.size
            try archive.addEntry(with: entry.file.path, type: link == nil ? .file : .symlink,
                                 uncompressedSize: size, permissions: entry.file.executable ? 0o700 : 0o600,
                                 compressionMethod: .deflate, bufferSize: chunkSize) { position, count in
                guard position == offset else { throw SandboxError("nonsequential ZIP write") }
                let data = try link ?? next()
                guard data.count <= chunkSize, data.count <= count, Int64(data.count) == min(Int64(count), size - offset) else {
                    throw SandboxError("archive source changed or chunk is invalid")
                }
                offset += Int64(data.count); return data
            }
            guard offset == size else { throw SandboxError("incomplete ZIP entry") }
        }
        public func appendDirectory(_ path: String) throws {
            try WorkspaceArchive.registerDirectory(path, paths: paths, directories: &directories)
            try archive.addEntry(with: path + "/", type: .directory, uncompressedSize: Int64(0), permissions: 0o700) { _, _ in Data() }
        }
        public func append(_ file: WorkspaceFile) throws {
            try file.validate()
            var metadata = file; metadata.data = Data()
            var offset = 0
            try append(Entry(file: metadata, size: Int64(file.data.count))) {
                let end = min(file.data.count, offset + chunkSize)
                defer { offset = end }; return file.data.subdata(in: offset..<end)
            }
        }
    }
    @discardableResult public static func write(_ url: URL, _ body: (Writer) throws -> Void) throws -> Summary {
        try temporary(directory: url.deletingLastPathComponent()) { stage in
            let summary: Summary = try {
                let writer = try Writer(stage)
                try body(writer); return writer.summary
            }() // Close ZIP before publishing it.
            guard chmod(stage.path, 0o600) == 0 else { throw SandboxError("cannot restrict archive") }
            let file = try openRegular(stage); defer { try? file.close() }; try file.synchronize()
            guard rename(stage.path, url.path) == 0 else { throw SandboxError("cannot commit ZIP archive") }
            return summary
        }
    }
    private static func register(_ entry: Entry, paths: inout Set<String>, summary: inout Summary) throws {
        let path = entry.file.path.precomposedStringWithCanonicalMapping.lowercased()
        guard paths.insert(path).inserted, paths.count <= ConfinedWorkspace.entryLimit else {
            throw SandboxError("archive duplicate path or entry limit exceeded")
        }
        let parts = path.split(separator: "/")
        for end in 1..<parts.count {
            guard !paths.contains(parts.prefix(end).joined(separator: "/")) else { throw SandboxError("archive file/directory conflict") }
        }
        guard !paths.contains(where: { $0.hasPrefix(path + "/") }) else { throw SandboxError("archive file/directory conflict") }
        let (bytes, overflow) = summary.bytes.addingReportingOverflow(entry.size)
        guard !overflow else { throw SandboxError("archive byte count cannot be represented") }
        summary.files += 1; summary.bytes = bytes
    }
    private static func registerDirectory(_ path: String, paths: Set<String>, directories: inout Set<String>) throws {
        _ = try ConfinedWorkspace.components(path)
        let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
        guard !paths.contains(normalized), !paths.contains(where: { normalized.hasPrefix($0 + "/") }),
              directories.insert(normalized).inserted,
              paths.count + directories.count <= ConfinedWorkspace.entryLimit else {
            throw SandboxError("archive duplicate directory or file/directory conflict")
        }
    }
    private static func checkDirectoryConflicts(_ path: String, directories: Set<String>) throws {
        let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
        guard !directories.contains(normalized), !directories.contains(where: { $0.hasPrefix(normalized + "/") }) else {
            throw SandboxError("archive file/directory conflict")
        }
    }
    // ZIPFoundation's Sequence ends on malformed headers. Check the declared
    // count separately so malformed entries cannot silently disappear.
    private static func declaredCount(_ input: FileHandle) throws -> Int {
        let size = try input.seekToEnd()
        let tailSize = min(size, 65557)
        try input.seek(toOffset: size - tailSize)
        let tail = try input.read(upToCount: Int(tailSize)) ?? Data()
        func le(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
            data[offset..<offset + count].reversed().reduce(0) { ($0 << 8) | UInt64($1) }
        }
        guard tail.count >= 22 else { throw SandboxError("truncated ZIP archive") }
        for i in stride(from: tail.count - 22, through: 0, by: -1) {
            guard le(tail, i, 4) == 0x06054b50, i + 22 + Int(le(tail, i + 20, 2)) == tail.count else { continue }
            guard le(tail, i + 4, 2) == 0, le(tail, i + 6, 2) == 0 else { throw SandboxError("split ZIP archives are not supported") }
            var count = le(tail, i + 10, 2)
            let endOffset = size - tailSize + UInt64(i)
            if endOffset >= 20 {
                try input.seek(toOffset: endOffset - 20)
                let locator = try input.read(upToCount: 20) ?? Data()
                if locator.count == 20, le(locator, 0, 4) == 0x07064b50 {
                    guard le(locator, 4, 4) == 0, le(locator, 16, 4) == 1 else { throw SandboxError("split ZIP64 archives are not supported") }
                    let offset = le(locator, 8, 8)
                    guard offset <= endOffset - 20 else { throw SandboxError("invalid ZIP64 directory offset") }
                    try input.seek(toOffset: offset)
                    let record = try input.read(upToCount: 56) ?? Data()
                    guard record.count == 56, le(record, 0, 4) == 0x06064b50,
                          le(record, 16, 4) == 0, le(record, 20, 4) == 0,
                          le(record, 24, 8) == le(record, 32, 8) else { throw SandboxError("invalid ZIP64 directory") }
                    count = le(record, 32, 8)
                }
            }
            guard count <= ConfinedWorkspace.entryLimit else { throw SandboxError("archive entry limit exceeded") }
            return Int(count)
        }
        throw SandboxError("invalid ZIP end record")
    }
    @discardableResult public static func read(_ url: URL,
        visit: (Entry, (_ consumer: (Data) throws -> Void) throws -> Void) throws -> Void = { _, extract in try extract { _ in } }
    ) throws -> Summary {
        try read(url, visitDirectory: { _ in }, visit: visit)
    }
    @discardableResult public static func read(_ url: URL,
        visitDirectory: (String) throws -> Void,
        visit: (Entry, (_ consumer: (Data) throws -> Void) throws -> Void) throws -> Void = { _, extract in try extract { _ in } }
    ) throws -> Summary {
        let input = try openRegular(url); defer { try? input.close() }
        let expected = try declaredCount(input)
        let archive = try ZIPFoundation.Archive(url: url, accessMode: .read)
        var paths = Set<String>(), directories = Set<String>(), summary = Summary(), observed = 0
        for zipEntry in archive {
            observed += 1
            guard observed <= expected, zipEntry.uncompressedSize <= Int64.max else { throw SandboxError("invalid ZIP entry count or size") }
            if zipEntry.type == .directory {
                let path = String(zipEntry.path.dropLast(zipEntry.path.hasSuffix("/") ? 1 : 0))
                try registerDirectory(path, paths: paths, directories: &directories)
                guard zipEntry.uncompressedSize == 0 else { throw SandboxError("invalid ZIP directory") }
                try visitDirectory(path)
                continue
            }
            var file = WorkspaceFile(path: zipEntry.path, data: Data(),
                executable: ((zipEntry.fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0) & 0o111 != 0)
            if zipEntry.type == .symlink {
                guard zipEntry.uncompressedSize <= 255, zipEntry.compressedSize <= 255 else { throw SandboxError("invalid ZIP symlink") }
                var target = Data()
                let crc = try archive.extract(zipEntry, bufferSize: chunkSize) { target.append($0) }
                guard crc == zipEntry.checksum, let text = String(data: target, encoding: .utf8) else { throw SandboxError("ZIP symlink integrity failed") }
                file.linkTarget = text; file.executable = false
            }
            let entry = Entry(file: file, size: file.linkTarget == nil ? Int64(zipEntry.uncompressedSize) : 0)
            try entry.validate(); try checkDirectoryConflicts(entry.file.path, directories: directories)
            try register(entry, paths: &paths, summary: &summary)
            var extracted = false
            func extract(_ consumer: (Data) throws -> Void) throws {
                guard !extracted else { throw SandboxError("ZIP entry already consumed") }; extracted = true
                if file.linkTarget != nil { return }
                var count: Int64 = 0
                let crc = try archive.extract(zipEntry, bufferSize: chunkSize) { data in
                    guard data.count <= chunkSize, Int64(data.count) <= entry.size - count else { throw SandboxError("invalid ZIP payload size") }
                    count += Int64(data.count); try consumer(data)
                }
                guard crc == zipEntry.checksum, count == entry.size else { throw SandboxError("ZIP entry integrity check failed") }
            }
            try visit(entry, extract)
            if !extracted { try extract { _ in } }
        }
        guard observed == expected else { throw SandboxError("ZIP entries are missing or damaged") }
        return summary
    }
    public static func isArchive(_ url: URL) throws -> Bool {
        let file = try openRegular(url); defer { try? file.close() }
        let prefix = try file.read(upToCount: 4)
        return prefix == Data([0x50, 0x4b, 3, 4]) || prefix == Data([0x50, 0x4b, 5, 6]) || prefix == Data([0x50, 0x4b, 6, 6])
    }
    public static func collect(_ url: URL) throws -> [WorkspaceFile] {
        var files: [WorkspaceFile] = []
        try read(url) { entry, extract in
            var file = entry.file; try extract { file.data.append($0) }; files.append(file)
        }
        return files.sorted { $0.path < $1.path }
    }
    public static func digest(_ url: URL) throws -> String {
        let input = try openRegular(url); defer { try? input.close() }
        var hash = SHA256()
        while true { let data = try autoreleasepool { try input.read(upToCount: chunkSize) ?? Data() }; if data.isEmpty { break }; hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func fromFile(_ source: URL, path: String, executable: Bool = false, to archive: URL) throws {
        let input = try openRegular(source); defer { try? input.close() }
        let size = try input.seekToEnd(); try input.seek(toOffset: 0)
        try write(archive) { writer in
            try writer.append(Entry(file: WorkspaceFile(path: path, data: Data(), executable: executable), size: Int64(size))) {
                try autoreleasepool { try input.read(upToCount: chunkSize) ?? Data() }
            }
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw SandboxError("source file grew during transfer") }
        }
    }
    public static func extractFile(_ archive: URL, path: String, to destination: URL?) throws {
        let summary = try read(archive)
        guard summary.files == 1 else { throw SandboxError("expected a single-file archive") }
        func copy(_ output: FileHandle) throws {
            try read(archive) { entry, extract in
                guard entry.file.path == path, entry.file.linkTarget == nil else { throw SandboxError("unexpected file in read response") }
                try extract { try output.write(contentsOf: $0) }
            }
        }
        if let destination { try atomic(destination, copy) } else { try copy(.standardOutput) }
    }
    public static func copy(_ source: URL, to destination: URL) throws {
        let input = try openRegular(source); defer { try? input.close() }
        try atomic(destination) { output in
            while true {
                let data = try autoreleasepool { try input.read(upToCount: chunkSize) ?? Data() }
                if data.isEmpty { break }; try output.write(contentsOf: data)
            }
        }
    }
}
