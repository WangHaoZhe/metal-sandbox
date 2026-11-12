import Foundation
import CryptoKit
import SandboxCore
import SandboxRuntime

public struct ArtifactSnapshot: Codable {
    public var id: String
    public var files: [WorkspaceFile]
}

/// Content-addressed controller-owned bytes, never a walk of the candidate's
/// container path. Hashes detect accidental/tampered records, not hostile UID
/// peers outside App Sandbox. Storage durability is atomic-file, not a database.
public final class ArtifactStore {
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) throws {
        self.directory = directory
        try SafeFiles.secureDirectory(directory)
    }
    private func canonical(_ files: [WorkspaceFile]) throws -> [WorkspaceFile] {
        guard files.count <= ConfinedWorkspace.entryLimit else { throw SandboxError("artifact file count exceeded") }
        var paths = Set<String>()
        func normalized(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        for file in files {
            try file.validate()
            guard paths.insert(normalized(file.path)).inserted else {
                throw SandboxError("artifact duplicate path")
            }
        }
        for path in paths {
            let parts = path.split(separator: "/")
            for end in 1..<parts.count {
                guard !paths.contains(parts.prefix(end).joined(separator: "/")) else { throw SandboxError("artifact file/directory conflict") }
            }
        }
        return files.sorted { $0.path < $1.path }
    }
    private func hash(_ files: [WorkspaceFile]) throws -> String {
        SHA256.hash(data: try JSON.data(files)).map { String(format: "%02x", $0) }.joined()
    }
    private func url(_ id: String) throws -> URL {
        guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw SandboxError("invalid artifact ID") }
        return directory.appendingPathComponent(id + ".json")
    }
    public func freeze(_ files: [WorkspaceFile]) throws -> ArtifactSnapshot {
        lock.lock(); defer { lock.unlock() }
        let sorted = try canonical(files), id = try hash(sorted)
        let artifact = ArtifactSnapshot(id: id, files: sorted), path = try url(id)
        if FileManager.default.fileExists(atPath: path.path) {
            let stored = try loadUnlocked(id)
            guard stored.files == sorted else { throw SandboxError("artifact collision or corruption") }
        } else { try SafeFiles.write(artifact, to: path) }
        return artifact
    }
    private func loadUnlocked(_ id: String) throws -> ArtifactSnapshot {
        let artifact = try SafeFiles.read(ArtifactSnapshot.self, from: url(id), limit: .max)
        let files = try canonical(artifact.files)
        guard artifact.id == id, try hash(files) == id else { throw SandboxError("artifact integrity check failed") }
        return ArtifactSnapshot(id: id, files: files)
    }
    public func load(_ id: String) throws -> ArtifactSnapshot {
        lock.lock(); defer { lock.unlock() }; return try loadUnlocked(id)
    }
}
