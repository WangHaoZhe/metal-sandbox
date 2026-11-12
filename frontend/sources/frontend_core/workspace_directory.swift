import Foundation
import UniformTypeIdentifiers

public struct WorkspaceEntry: Decodable, Identifiable, Equatable {
    public enum Kind: String, Decodable { case directory, file, symlink, other }
    public let name: String
    public let path: String
    public let kind: Kind
    public let size: Int64
    public let modifiedAt: Double
    public var id: String { path }
}

/// Owns a CLI-downloaded, read-only preview copy, never a workspace URL.
public final class WorkspacePreview {
    public let file: URL
    public private(set) var text: String?
    public private(set) var textTruncated = false
    private let folder: URL
    public init(name: String) throws {
        guard WorkspaceDirectory.validPath(name), !name.contains("/") else { throw CLIError(ui("无效预览文件名", "Invalid preview filename")) }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        file = folder.appendingPathComponent(name)
    }
    public func prepare() throws {
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw CLIError(ui("预览副本不是普通文件", "Preview copy is not a regular file")) }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        let type = UTType(filenameExtension: file.pathExtension)
        let plain = type.map { $0.conforms(to: .text) && !$0.conforms(to: .rtf) && !$0.conforms(to: .image) } ?? false
        guard plain || type == nil || type?.isDynamic == true else { return }
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        let limit = 4 * 1024 * 1024
        let data = try input.read(upToCount: limit + 1) ?? Data()
        let prefix = Data(data.prefix(limit))
        guard !prefix.contains(0) else { return }
        for dropped in 0...(data.count > limit ? min(3, prefix.count) : 0) {
            if let value = String(data: prefix.dropLast(dropped), encoding: .utf8) {
                text = value; textTruncated = data.count > limit
                break
            }
        }
    }
    public func close() { try? FileManager.default.removeItem(at: folder) }
    deinit { close() }
}

public struct WorkspaceDirectory: Decodable {
    public let path: String
    public let entries: [WorkspaceEntry]
    public let nextAfter: String?

    public static func validPath(_ path: String, allowRoot: Bool = false) -> Bool {
        if allowRoot && path == "." { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 2048 && parts.count <= 32 && !path.contains("\0")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }
    }

    public func validate(requestedPath: String, after: String?) throws {
        guard path == requestedPath, Self.validPath(path, allowRoot: true), entries.count <= 256 else { throw CLIError(ui("无效目录响应", "Invalid directory response")) }
        var previous = after
        for entry in entries {
            guard Self.validPath(entry.name), !entry.name.contains("/"),
                  entry.path == (path == "." ? entry.name : path + "/" + entry.name),
                  Self.validPath(entry.path), entry.size >= 0, entry.modifiedAt.isFinite,
                  previous.map({ entry.name > $0 }) ?? true else { throw CLIError(ui("目录响应包含无效、重复或越界条目", "Directory response contains invalid, duplicate or out-of-bounds entries")) }
            previous = entry.name
        }
        if let nextAfter {
            guard nextAfter == entries.last?.name, !entries.isEmpty else { throw CLIError(ui("无效目录分页游标", "Invalid directory pagination cursor")) }
        }
    }
}
