import Foundation
import Darwin
import SandboxCore

/// Must be instantiated in SandboxHost for candidate files. Manager-side use is
/// only for its own artifact store, never to walk an untrusted container path.
public final class ConfinedWorkspace {
    public static let entryLimit = 1000
    private let root: Int32
    public init(directory: URL) throws {
        root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw SandboxError("cannot open workspace root") }
    }
    deinit { close(root) }
    private init(descriptor: Int32) { root = descriptor }
    public func replaceTests(from archive: URL) throws {
        _ = try TaskPackage.testsFingerprint(archive)
        let fd = try directory(["tests"], create: true)
        let tests = ConfinedWorkspace(descriptor: fd)
        try tests.removeAll()
        try importArchive(from: archive)
    }
    public static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, path.utf8.count <= 2048, parts.count <= 32,
              !path.contains("\0"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              parts.allSatisfy({ $0.utf8.count <= 255 }) else { throw SandboxError("invalid workspace-relative path") }
        return parts
    }
    private func directory(_ parts: [String], create: Bool) throws -> Int32 {
        var fd = dup(root)
        guard fd >= 0 else { throw SandboxError("dup workspace root failed") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        do {
            for part in parts {
                if create, mkdirat(fd, part, 0o700) != 0, errno != EEXIST { throw SandboxError("mkdirat failed") }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw SandboxError("workspace parent is not an accessible real directory") }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    public func validateDirectory(_ path: String) throws {
        let fd = try directory(path == "." ? [] : Self.components(path), create: false)
        close(fd)
    }
    public func validateFileOrDirectory(_ path: String) throws {
        if path == "." { try validateDirectory(path); return }
        let parts = try Self.components(path)
        let parent = try directory(Array(parts.dropLast()), create: false)
        defer { close(parent) }
        var st = stat()
        guard fstatat(parent, parts.last!, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw SandboxError("workspace entry no longer exists") }
        let kind = st.st_mode & S_IFMT
        guard kind == S_IFDIR || (kind == S_IFREG && st.st_nlink == 1) else {
            throw SandboxError("only real workspace files and directories can be revealed")
        }
    }
    /// Metadata only. Never open file contents or follow directory/file links.
    /// Pages are name-ordered observations, not a snapshot of a changing tree.
    public func listDirectory(_ path: String = ".", after: String? = nil) throws -> WorkspaceDirectory {
        if let after { guard try Self.components(after).count == 1 else { throw SandboxError("invalid directory cursor") } }
        let fd = try directory(path == "." ? [] : Self.components(path), create: false)
        defer { close(fd) }
        let scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard scan >= 0 else { throw SandboxError("cannot enumerate workspace directory") }
        guard let stream = fdopendir(scan) else { close(scan); throw SandboxError("fdopendir failed") }
        defer { closedir(stream) }
        var names: [String] = []
        var count = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw SandboxError("workspace enumeration failed") }; break
            }
            guard let name = withUnsafePointer(to: &entry.pointee.d_name, { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(validatingCString: $0) }
            }) else { throw SandboxError("workspace filenames must be valid UTF-8") }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= 100_000 else { throw SandboxError("directory exceeds 100000 entries; listing not returned") }
            if let after, name <= after { continue }
            names.append(name)
        }
        names.sort()
        var entries: [WorkspaceEntry] = []
        for name in names.prefix(256) {
            let relative = path == "." ? name : path + "/" + name
            _ = try Self.components(relative)
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw SandboxError("directory changed; refresh its listing") }
            let kind: WorkspaceEntry.Kind
            switch st.st_mode & S_IFMT {
            case S_IFDIR: kind = .directory
            case S_IFREG: kind = .file
            case S_IFLNK: kind = .symlink
            default: kind = .other
            }
            entries.append(WorkspaceEntry(name: name, path: relative, kind: kind, size: max(0, st.st_size),
                                          modifiedAt: Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9),
                                          executable: kind == .file && st.st_mode & 0o111 != 0))
        }
        return WorkspaceDirectory(path: path, entries: entries, nextAfter: names.count > 256 ? entries.last?.name : nil)
    }
    private func archiveFile(_ fd: Int32, path: String, writer: WorkspaceArchive.Writer) throws {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0 else { throw SandboxError("reject special file or hardlink") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let entry = WorkspaceArchive.Entry(file: WorkspaceFile(path: path, data: Data(), executable: before.st_mode & 0o111 != 0), size: before.st_size)
        try writer.append(entry) { try autoreleasepool { try input.read(upToCount: WorkspaceArchive.chunkSize) ?? Data() } }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              after.st_nlink == 1,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw SandboxError("workspace file changed during read or snapshot; retry") }
    }
    public func read(_ path: String) throws -> WorkspaceFile {
        try WorkspaceArchive.temporary { archive in
            try exportArchive(to: archive, path: path)
            guard let file = try WorkspaceArchive.collect(archive).first else { throw SandboxError("missing file") }
            return file
        }
    }
    /// Bounded, append-friendly reads; the cursor identifies an inode and byte
    /// offset. Unlike workspace snapshots, a growing log need not stay frozen.
    func readGrowingFile(_ path: String, after: String?) throws -> TrajectoryPage {
        let parts = try Self.components(path)
        let parent = try directory(Array(parts.dropLast()), create: false)
        defer { close(parent) }
        let fd = openat(parent, parts.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SandboxError("cannot open trajectory log") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_size >= 0 else {
            throw SandboxError("trajectory must be a regular file without hardlinks")
        }
        let identity = "\(st.st_dev):\(st.st_ino):\(st.st_birthtimespec.tv_sec):\(st.st_birthtimespec.tv_nsec)"
        var offset: Int64 = 0, reset = false
        if let after {
            let cursor = after.split(separator: ":", omittingEmptySubsequences: false)
            guard cursor.count == 5, let value = Int64(cursor[4]), value >= 0,
                  cursor.prefix(4).allSatisfy({ Int64($0) != nil }) else { throw SandboxError("invalid trajectory cursor") }
            if cursor.prefix(4).joined(separator: ":") == identity, value <= st.st_size { offset = value }
            else { reset = true }
        }
        var bytes = [UInt8](repeating: 0, count: Int(min(256 * 1024, st.st_size - offset)))
        let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
        guard count >= 0 else { throw SandboxError("trajectory read failed") }
        offset += Int64(count)
        return TrajectoryPage(data: Data(bytes.prefix(count)), nextAfter: identity + ":\(offset)", reset: reset, atEnd: offset >= st.st_size)
    }
    public func write(_ file: WorkspaceFile) throws {
        try file.validate()
        var offset = 0
        var metadata = file; metadata.data = Data()
        try writeEntry(WorkspaceArchive.Entry(file: metadata, size: Int64(file.data.count))) { consume in
            while offset < file.data.count {
                let end = min(file.data.count, offset + WorkspaceArchive.chunkSize)
                try consume(file.data.subdata(in: offset..<end)); offset = end
            }
        }
    }
    private func writeEntry(_ entry: WorkspaceArchive.Entry, extract: (_ consumer: (Data) throws -> Void) throws -> Void) throws {
        let file = entry.file
        try file.validate()
        let parts = try Self.components(file.path)
        let parent = try directory(Array(parts.dropLast()), create: true)
        defer { close(parent) }
        // Replace entries, never open/truncate an existing inode or follow links.
        let name = ".write-" + UUID().uuidString.lowercased()
        if let target = file.linkTarget {
            guard symlinkat(target, parent, name) == 0 else { throw SandboxError("cannot stage workspace symlink") }
            defer { _ = unlinkat(parent, name, 0) }
            guard renameat(parent, name, parent, parts.last!) == 0 else { throw SandboxError("cannot replace workspace symlink") }
            return
        }
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SandboxError("cannot stage workspace file") }
        defer { close(fd); _ = unlinkat(parent, name, 0) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var written: Int64 = 0
        try extract { data in try output.write(contentsOf: data); written += Int64(data.count) }
        guard written == entry.size, fchmod(fd, file.executable ? 0o700 : 0o600) == 0,
              renameat(parent, name, parent, parts.last!) == 0 else { throw SandboxError("workspace replace failed") }
    }
    public func importArchive(from url: URL) throws {
        // Validate the complete staged archive before applying any file. Import
        // still merges per file; filesystem failures can leave a partial merge.
        try WorkspaceArchive.read(url)
        try WorkspaceArchive.read(url, visitDirectory: { path in
            let fd = try self.directory(Self.components(path), create: true)
            close(fd)
        }) { entry, extract in try writeEntry(entry, extract: extract) }
    }
    public func export() throws -> [WorkspaceFile] {
        try WorkspaceArchive.temporary { archive in
            try exportArchive(to: archive)
            return try WorkspaceArchive.collect(archive)
        }
    }
    public func exportArchive(to url: URL, path: String? = nil, subdirectory: String? = nil) throws {
        guard path == nil || subdirectory == nil else { throw SandboxError("choose a file or a directory, not both") }
        try WorkspaceArchive.write(url) { writer in
        if let path {
            let parts = try Self.components(path)
            let parent = try directory(Array(parts.dropLast()), create: false)
            defer { close(parent) }
            let fd = openat(parent, parts.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw SandboxError("cannot open workspace file") }
            defer { close(fd) }
            try archiveFile(fd, path: path, writer: writer)
            return
        }
        var nodes = 0
        func walk(_ fd: Int32, _ prefix: String, depth: Int) throws {
            guard depth <= 32 else { throw SandboxError("workspace nesting exceeds limit") }
            // openat(.) gets an independent directory offset, unlike dup().
            let scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard scan >= 0 else { throw SandboxError("cannot enumerate workspace") }
            guard let stream = fdopendir(scan) else { close(scan); throw SandboxError("fdopendir failed") }
            defer { closedir(stream) }
            var empty = true
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw SandboxError("workspace enumeration failed") }
                    break
                }
                guard let name = withUnsafePointer(to: &entry.pointee.d_name, { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(validatingCString: $0) }
                }) else { throw SandboxError("workspace filenames must be valid UTF-8") }
                if name == "." || name == ".." { continue }
                empty = false
                nodes += 1
                guard nodes <= Self.entryLimit else { throw SandboxError("workspace entry limit exceeded") }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                _ = try Self.components(path)
                var entryStat = stat()
                guard fstatat(fd, name, &entryStat, AT_SYMLINK_NOFOLLOW) == 0 else { throw SandboxError("workspace entry changed") }
                if entryStat.st_mode & S_IFMT == S_IFLNK {
                    var buffer = [UInt8](repeating: 0, count: 256)
                    let count = readlinkat(fd, name, &buffer, buffer.count)
                    guard count > 0, count < buffer.count,
                          let target = String(bytes: buffer.prefix(count), encoding: .utf8) else { throw SandboxError("unsupported workspace symlink") }
                    let file = WorkspaceFile(path: path, data: Data(), linkTarget: target)
                    try file.validate()
                    try writer.append(file)
                    continue
                }
                let child = openat(fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw SandboxError("workspace export rejects links or inaccessible entries") }
                defer { close(child) }
                var st = stat()
                guard fstat(child, &st) == 0 else { throw SandboxError("workspace fstat failed") }
                if st.st_mode & S_IFMT == S_IFDIR { try walk(child, path, depth: depth + 1) }
                else {
                    try archiveFile(child, path: path, writer: writer)
                }
            }
            if empty && !prefix.isEmpty { try writer.appendDirectory(prefix) }
        }
        if let subdirectory {
            let parts = try Self.components(subdirectory)
            let fd = try directory(parts, create: false)
            defer { close(fd) }
            try walk(fd, subdirectory, depth: 0)
        } else { try walk(root, "", depth: 0) }
        }
    }

    /// Maintenance only: called by the signed Host on its own container Data.
    /// Unlink links themselves; never follow them, truncate hardlinks, cross a
    /// mount, or enumerate candidate paths from the unsandboxed controller.
    public func removeAll(preservingLinks: [String: String] = [:]) throws {
        for path in preservingLinks.keys { _ = try Self.components(path) }
        var rootStat = stat(), nodes = 0
        guard fstat(root, &rootStat) == 0 else { throw SandboxError("cannot inspect purge root") }
        func walk(_ fd: Int32, path: String, depth: Int) throws -> Bool {
            var retained = false
            guard depth <= 64 else { throw SandboxError("purge nesting limit exceeded; deletion incomplete") }
            var parentStat = stat()
            guard fstat(fd, &parentStat) == 0, parentStat.st_uid == getuid(), parentStat.st_dev == rootStat.st_dev else {
                throw SandboxError("unsafe purge directory: \(path)")
            }
            // macOS may forbid chmod on its container root even though its
            // entries are writable. Only repair modes that actually need it.
            if parentStat.st_mode & 0o700 != 0o700, fchmod(fd, parentStat.st_mode | 0o700) != 0 {
                throw SandboxError("cannot make purge directory writable: \(path) (errno \(errno))")
            }
            let scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard scan >= 0 else { throw SandboxError("cannot enumerate purge directory") }
            guard let stream = fdopendir(scan) else { close(scan); throw SandboxError("cannot scan purge directory") }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw SandboxError("purge enumeration failed") }
                    break
                }
                guard let name = withUnsafePointer(to: &entry.pointee.d_name, { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(validatingCString: $0) }
                }) else { throw SandboxError("purge filename is not UTF-8; deletion incomplete") }
                if name == "." || name == ".." { continue }
                nodes += 1
                guard nodes <= 100_000 else { throw SandboxError("purge entry limit exceeded; deletion incomplete") }
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw SandboxError("purge entry changed") }
                let relative = path.isEmpty ? name : path + "/" + name
                if let expected = preservingLinks[relative] {
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = readlinkat(fd, name, &bytes, bytes.count)
                    guard st.st_mode & S_IFMT == S_IFLNK, count > 0, count < bytes.count,
                          String(decoding: bytes.prefix(count), as: UTF8.self) == expected else {
                        throw SandboxError("unexpected protected container link: \(relative)")
                    }
                    retained = true
                    continue
                }
                if st.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw SandboxError("cannot open real purge directory") }
                    let keep: Bool
                    do { keep = try walk(child, path: relative, depth: depth + 1); close(child) }
                    catch { close(child); throw error }
                    if keep { retained = true; continue }
                    guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw SandboxError("purge directory is not empty or removable") }
                } else {
                    guard unlinkat(fd, name, 0) == 0 else { throw SandboxError("cannot unlink purge entry: \(path)/\(name) (errno \(errno))") }
                }
            }
            return retained
        }
        _ = try walk(root, path: "", depth: 0)
    }
}
