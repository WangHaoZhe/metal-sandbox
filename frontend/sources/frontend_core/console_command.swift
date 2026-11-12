import Foundation

/// Per-command settings for the public enter console. The CLI, not the UI,
/// parses shell syntax and executes it inside the sandbox.
public struct ConsoleCommand: Encodable {
    public let line: String
    public let cwd: String?
    public let timeout: Double

    public init(line: String, cwd: String, timeout: Double) {
        self.line = line; self.cwd = cwd.isEmpty ? nil : cwd; self.timeout = timeout
    }

    public func wireLine() throws -> String {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !line.contains("\0"), !line.contains("\n"), !line.contains("\r"), line.utf8.count <= 8192 else {
            throw CLIError(ui("一次发送一行命令（最多 8 KiB）；多行内容请保存为脚本后运行。", "Send one command line at a time (up to 8 KiB); save multiple lines as a script to run them."))
        }
        guard timeout.isFinite, timeout > 0 else { throw CLIError(ui("超时必须是正数秒数", "Timeout must be a positive number of seconds")) }
        if let cwd, !WorkspaceDirectory.validPath(cwd, allowRoot: true) { throw CLIError(ui("工作目录须为 workspace 相对路径；留空沿用控制台当前目录。", "Use a workspace-relative directory; leave it empty to keep the console's current directory.")) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return ":run " + String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public enum ConsoleTemplate: String, CaseIterable {
    case workingDirectory, readPrompt

    public var title: String {
        switch self {
        case .workingDirectory: return ui("打印工作目录", "Print Working Directory")
        case .readPrompt: return ui("读取题目", "Read Task Instruction")
        }
    }

    public var line: String {
        switch self {
        case .workingDirectory: return "pwd"
        case .readPrompt: return "cat instruction.md"
        }
    }
}
