import Foundation

/// Workspace files, not execution history. nil means the file is absent.
public struct PreparationFiles: Equatable {
    public var script: String?
    public var instruction: String?
    public init(script: String? = nil, instruction: String? = nil) {
        self.script = script; self.instruction = instruction
    }

    /// Preview only the operator-selected local input. The public import CLI
    /// remains responsible for validating and copying the public agent/ tree.
    public static func script(inTaskPackage directory: URL) throws -> String {
        let root = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw CLIError(ui("请选择题目文件夹，不接受 ZIP 或链接。", "Select a task directory, not a ZIP archive or symbolic link.")) }
        let agent = directory.appendingPathComponent("agent")
        guard let value = try? agent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              value.isDirectory == true, value.isSymbolicLink != true else { throw CLIError(ui("题包需要 agent/ 文件夹。", "The task package requires an agent/ directory.")) }
        for name in ["instruction.md", "setup.sh"] {
            let file = agent.appendingPathComponent(name)
            let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard value.isRegularFile == true, value.isSymbolicLink != true, (value.fileSize ?? 0) > 0 else {
                throw CLIError(ui("题包 agent/ 中的 \(name) 必须是非空普通文件。", "agent/\(name) must be a nonempty regular file."))
            }
        }
        let input = try FileHandle(forReadingFrom: agent.appendingPathComponent("setup.sh"))
        defer { try? input.close() }
        let data = try input.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 4 * 1024 * 1024 else { throw CLIError(ui("setup.sh 超出准备脚本文本编辑器的预览范围。", "setup.sh exceeds the preparation editor's preview limit.")) }
        guard let script = String(data: data, encoding: .utf8), !script.contains("\0") else { throw CLIError(ui("setup.sh 必须是 UTF-8 文本。", "setup.sh must be UTF-8 text.")) }
        return script
    }

    public static func read(id: String, client: CLIClient) async throws -> Self {
        var entries: [WorkspaceEntry] = []
        var after: String?
        repeat {
            var args = ["ls", id, "--", "."]
            if let after { args += ["--after", after] }
            guard let page = try await client.sandbox(args).reply().directory else { throw CLIError(ui("CLI 未返回目录信息", "The CLI did not return directory information")) }
            try page.validate(requestedPath: ".", after: after)
            entries += page.entries.filter { ["setup.sh", "instruction.md"].contains($0.name) }
            after = page.nextAfter
        } while after != nil
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("preparation_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var files: [String: String] = [:]
        for entry in entries {
            guard entry.kind == .file else { throw CLIError(ui(entry.name + " 不是普通文件；不会跟随链接。", entry.name + " is not a regular file; symbolic links are not followed.")) }
            let file = directory.appendingPathComponent(entry.name)
            _ = try await client.sandbox(["read", id, entry.path, "--out", file.path], timeout: .greatestFiniteMagnitude).checked()
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            let data = try input.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 4 * 1024 * 1024 else { throw CLIError(ui(entry.name + " 超出文本编辑器预览范围，请在终端中编辑。文件传输没有大小上限。", entry.name + " exceeds the editor's preview limit. Edit it in Terminal. File transfers have no size limit.")) }
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw CLIError(ui(entry.name + " 不是 UTF-8 文本。", entry.name + " is not UTF-8 text.")) }
            files[entry.name] = text
        }
        return Self(script: files["setup.sh"], instruction: files["instruction.md"])
    }

    public func save(write: (String, String) async throws -> Void) async throws {
        if let script { try await write("setup.sh", script) }
        if let instruction { try await write("instruction.md", instruction) }
    }

    /// Every replica gets the original bytes. A failed replica does not prevent
    /// later submissions, and no submission is ever retried automatically.
    public static func prepareReplicas(ids: [String], script: String,
                                      importTask: ((String) async throws -> Void)? = nil,
                                      apply: (String, String) async throws -> Void) async -> [String] {
        let execute = !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard execute || importTask != nil else { return [] }
        var failures: [String] = []
        for id in ids {
            do {
                try await importTask?(id)
                if execute { try await apply(id, script) }
            }
            catch { failures.append(id + ": " + error.localizedDescription) }
        }
        return failures
    }
}
