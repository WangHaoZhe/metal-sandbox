import Foundation
import Darwin
import CryptoKit
import SandboxCore

/// Package an operator-selected directory before sending it through upload.
/// No source script is executed, and payloads remain disk-backed and chunked.
public enum TaskPackage {
    public static func testsFingerprint(_ archive: URL) throws -> String {
        var entries: [String] = [], entrypoint = false
        try WorkspaceArchive.read(archive, visitDirectory: { path in
            guard path == "tests" || path.hasPrefix("tests/") else { throw SandboxError("test archive contains another directory") }
            entries.append("directory:" + path)
        }) { entry, extract in
            guard entry.file.path.hasPrefix("tests/"), entry.file.linkTarget == nil else {
                throw SandboxError("test archive must contain only regular files under tests/")
            }
            var hash = SHA256()
            try extract { hash.update(data: $0) }
            entries.append(try JSON.string([entry.file.path, String(entry.file.executable), String(entry.size),
                                           hash.finalize().map { String(format: "%02x", $0) }.joined()]))
            if entry.file.path == "tests/test.sh" { entrypoint = entry.size > 0 }
        }
        guard entrypoint else { throw SandboxError("test archive requires nonempty tests/test.sh") }
        return SHA256.hash(data: try JSON.data(entries.sorted())).map { String(format: "%02x", $0) }.joined()
    }

    /// Copy only tests/, never the task prompt, setup script, or candidate files.
    public static func prepareTests(_ source: URL, to destination: URL) throws {
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw SandboxError("verification --from requires a task folder containing tests/test.sh")
        }
        let workspace = try ConfinedWorkspace(directory: source)
        for path in ["agent/instruction.md", "agent/setup.sh"] {
            guard !(try workspace.read(path)).data.isEmpty else { throw SandboxError("task folder requires nonempty " + path) }
        }
        try WorkspaceArchive.temporary { archive in
            guard !archive.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") else {
                throw SandboxError("select the task folder, not a parent of the temporary directory")
            }
            try workspace.exportArchive(to: archive, subdirectory: "tests")
            var entrypoint = false
            try WorkspaceArchive.read(archive) { entry, _ in
                guard entry.file.path.hasPrefix("tests/"), entry.file.linkTarget == nil else {
                    throw SandboxError("verification tests must be regular files under tests/")
                }
                if entry.file.path == "tests/test.sh" { entrypoint = entry.size > 0 }
            }
            guard entrypoint else { throw SandboxError("task folder missing nonempty tests/test.sh; workspace unchanged") }
            try WorkspaceArchive.copy(archive, to: destination)
        }
    }

    public static func prepare(_ source: URL, to destination: URL) throws {
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw SandboxError("task import accepts a folder only; select the task folder containing agent/")
        }
        let agent = source.appendingPathComponent("agent")
        guard lstat(agent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw SandboxError("task folder requires a real agent/ directory; workspace unchanged")
        }
        try WorkspaceArchive.temporary { archive in
            guard !archive.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") else {
                throw SandboxError("select the task directory, not a parent of the temporary directory")
            }
            // Copy the explicit public subtree, flattened into workspace.
            // Sibling tests/ is stored separately by the controller.
            try ConfinedWorkspace(directory: agent).exportArchive(to: archive)
            var required: Set<String> = ["instruction.md", "setup.sh"]
            try WorkspaceArchive.read(archive) { entry, _ in
                guard entry.file.linkTarget == nil else { throw SandboxError("task package does not support links: " + entry.file.path) }
                if required.contains(entry.file.path) {
                    guard entry.size > 0 else { throw SandboxError("task package requires nonempty regular " + entry.file.path) }
                    required.remove(entry.file.path)
                }
            }
            guard required.isEmpty else {
                throw SandboxError("task agent/ directory missing: " + required.sorted().joined(separator: ", ") + "; workspace unchanged")
            }
            try WorkspaceArchive.copy(archive, to: destination)
        }
    }
}
