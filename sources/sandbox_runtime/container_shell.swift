import Foundation
import Darwin
import SandboxCore

public struct ContainerShellPermissionDenied: Error, CustomStringConvertible {
    public let description: String
}

/// Removes only the drained, fixed-layout OS shell after the signed Host has
/// purged its own Data. Never follows links or walks arbitrary candidate paths.
public enum ContainerShell {
    public static var root: URL { DevelopmentPolicy.operatorHome.appendingPathComponent("Library/Containers") }
    /// Read-only exact-entry lookup for the trusted CLI Finder action.
    public static func locations(_ identifiers: [String], root: URL = root) throws -> (urls: [URL], missing: [String]) {
        guard !identifiers.isEmpty, identifiers.count <= 512 else {
            throw SandboxError("reveal-containers requires 1...512 complete physical bundle IDs")
        }
        let identifiers = Array(Set(identifiers)).sorted()
        for identifier in identifiers { try AppSandboxFactory.validateInstanceIdentifier(identifier) }
        var parent = stat()
        guard lstat(root.path, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == getuid() else {
            throw SandboxError("container parent must be an accessible real directory owned by this user")
        }
        var urls: [URL] = [], missing: [String] = []
        for identifier in identifiers {
            let url = root.appendingPathComponent(identifier, isDirectory: true)
            var entry = stat()
            if lstat(url.path, &entry) != 0 {
                if errno == ENOENT { missing.append(identifier); continue }
                throw SandboxError("cannot inspect container directory: \(String(cString: strerror(errno)))")
            }
            guard entry.st_mode & S_IFMT == S_IFDIR, entry.st_uid == getuid() else {
                throw SandboxError("refusing a container link, special file or mismatched owner: \(identifier)")
            }
            urls.append(url)
        }
        return (urls, missing)
    }
    private static let metadata = ".com.apple.containermanagerd.metadata.plist"
    private static let aliases = [
        "Data/Library/Preferences/com.apple.security.plist": "../../../../../Preferences/com.apple.security.plist",
        "Data/Library/Preferences/com.apple.security_common.plist": "../../../../../Preferences/com.apple.security_common.plist",
    ]
    public static func remove(_ identifier: String, root: URL = root) throws {
        try AppSandboxFactory.validateInstanceIdentifier(identifier)
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw SandboxError("cannot open container parent: \(String(cString: strerror(errno)))") }
        defer { close(parent) }
        let fd = openat(parent, identifier, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return }
        guard fd >= 0 else { throw SandboxError("container shell must be an accessible real directory") }
        defer { close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_uid == getuid() else { throw SandboxError("container shell owner mismatch") }
        func removalError(_ operation: String) -> Error {
            let code = errno
            if code == EPERM || code == EACCES {
                return ContainerShellPermissionDenied(description: "Task data was removed, but macOS denied removal of system container shell \(identifier) (\(operation)); the shell remains. Run sandboxctl sandbox cleanup-deleted to preview leftovers, and add --confirm to attempt cleanup. This command cannot repair system permissions.")
            }
            return SandboxError("\(operation): \(String(cString: strerror(code)))")
        }
        func entries(_ fd: Int32) throws -> [String] {
            let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard copy >= 0 else { throw SandboxError("cannot inspect drained shell") }
            guard let stream = fdopendir(copy) else { close(copy); throw SandboxError("cannot enumerate drained shell") }
            defer { closedir(stream) }
            var names: [String] = []
            while true {
                errno = 0
                guard let item = readdir(stream) else {
                    guard errno == 0 else { throw SandboxError("shell enumeration failed") }; break
                }
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(validatingCString: $0) }
                }
                guard let name else { throw SandboxError("invalid shell filename") }
                if name != "." && name != ".." { names.append(name) }
                guard names.count <= 8 else { throw SandboxError("container still has unexpected files; shell not removed") }
            }
            return names.sorted()
        }
        func walk(_ fd: Int32, _ prefix: String, deleting: Bool) throws {
            for name in try entries(fd) {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
                      st.st_uid == getuid(), st.st_dev == original.st_dev else { throw SandboxError("shell entry changed or has unsafe ownership") }
                if ["Data", "Data/Library", "Data/Library/Preferences"].contains(path) {
                    guard st.st_mode & S_IFMT == S_IFDIR else { throw SandboxError("shell directory replaced by a link or special file") }
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw SandboxError("cannot open shell directory") }
                    do { try walk(child, path, deleting: deleting); close(child) } catch { close(child); throw error }
                    if deleting && unlinkat(fd, name, AT_REMOVEDIR) != 0 { throw removalError("remove shell directory") }
                } else if let target = aliases[path] {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let count = readlinkat(fd, name, &buffer, buffer.count)
                    guard st.st_mode & S_IFMT == S_IFLNK, count > 0, count < buffer.count,
                          String(decoding: buffer.prefix(count), as: UTF8.self) == target else { throw SandboxError("unexpected system alias; refusing shell deletion") }
                    if deleting && unlinkat(fd, name, 0) != 0 { throw removalError("unlink system alias") }
                } else if path == metadata || path == ".DS_Store" {
                    guard st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_size <= 1024 * 1024 else { throw SandboxError("unsafe container metadata") }
                    if deleting && unlinkat(fd, name, 0) != 0 { throw removalError("unlink container metadata") }
                } else { throw SandboxError("container is not a drained shell (\(path)); no unknown files will be removed") }
            }
        }
        // Preflight the complete fixed layout before the first mutation; then
        // revalidate every entry. ENOTEMPTY on a race is failure, not success.
        try walk(fd, "", deleting: false)
        try walk(fd, "", deleting: true)
        var current = stat()
        guard fstatat(parent, identifier, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == original.st_dev, current.st_ino == original.st_ino else { throw SandboxError("container root changed during shell removal") }
        guard unlinkat(parent, identifier, AT_REMOVEDIR) == 0 else {
            throw removalError("remove container root")
        }
    }
}
