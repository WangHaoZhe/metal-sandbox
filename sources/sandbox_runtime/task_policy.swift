import Foundation
import SandboxCore

/// Operator-chosen task scheduling, not a GPU detector or a security boundary.
/// A match covers the submitted task and its descendants, not individual syscalls.
public struct TaskPolicy: Codable {
    public struct Rule: Codable {
        public var executable: String
        public var argumentPrefix: [String]
        public init(_ executable: String, argumentPrefix: [String] = []) {
            self.executable = executable; self.argumentPrefix = argumentPrefix
        }
        private enum CodingKeys: String, CodingKey { case executable, argumentPrefix }
        public init(from decoder: Decoder) throws {
            try TaskPolicy.requireKeys(decoder, allowed: ["executable", "argumentPrefix"])
            let values = try decoder.container(keyedBy: CodingKeys.self)
            executable = try values.decode(String.self, forKey: .executable)
            argumentPrefix = try values.contains(.argumentPrefix) ? values.decode([String].self, forKey: .argumentPrefix) : []
        }
    }
    public enum Mode: String, CodingKey { case allowlist = "parallel", blocklist = "serial" }
    public var mode: Mode
    public var rules: [Rule]
    public init(parallel: [Rule] = []) { mode = .allowlist; rules = parallel }
    public init(serial: [Rule]) { mode = .blocklist; rules = serial }
    public init(from decoder: Decoder) throws {
        try Self.requireKeys(decoder, allowed: ["parallel", "serial"])
        let values = try decoder.container(keyedBy: Mode.self)
        guard values.allKeys.count == 1, let key = values.allKeys.first else {
            throw SandboxError("task policy requires exactly one of parallel or serial")
        }
        mode = key; rules = try values.decode([Rule].self, forKey: key)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Mode.self)
        try values.encode(rules, forKey: mode)
    }
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private static func requireKeys(_ decoder: Decoder, allowed: Set<String>) throws {
        let keys = try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue)
        guard Set(keys).isSubset(of: allowed) else { throw SandboxError("unknown task policy field") }
    }

    public static func development(toolchain: InstalledClang) throws -> TaskPolicy {
        guard let url = Bundle.module.url(forResource: "default_task_policy", withExtension: "json") else {
            throw SandboxError("missing default_task_policy.json")
        }
        let template = try SafeFiles.read(TaskPolicy.self, from: url, limit: 128 * 1024)
        // Only the shipped template uses placeholders. Instance policies contain
        // resolved absolute paths, so their meaning cannot change on restore.
        let tools: [String: String?] = [
            "${compiler}": toolchain.compiler, "${cxxCompiler}": toolchain.cxxCompiler,
            "${make}": toolchain.buildToolsDirectory.map { $0 + "/make" },
            "${git}": toolchain.buildToolsDirectory.map { $0 + "/git" },
            "${ninja}": toolchain.ninja, "${metalCompiler}": toolchain.metalCompiler,
            "${metallib}": toolchain.metallib, "${cmake}": toolchain.cmake,
        ]
        var policy = template
        policy.rules = template.rules.compactMap { rule in
            guard let replacement = tools[rule.executable] else { return rule }
            return replacement.map { Rule($0, argumentPrefix: rule.argumentPrefix) }
        }
        try policy.validate()
        return policy
    }

    public func validate() throws {
        guard rules.count <= 128 else { throw SandboxError("at most 128 task scheduling rules") }
        for rule in rules {
            guard rule.executable.hasPrefix("/"), !rule.executable.contains("\0"),
                  rule.executable.utf8.count <= 4096,
                  URL(fileURLWithPath: rule.executable).standardizedFileURL.path == rule.executable,
                  rule.argumentPrefix.count <= 64,
                  rule.argumentPrefix.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 }) else {
                throw SandboxError("task policy requires exact absolute executable paths and bounded argument prefixes")
            }
        }
    }

    public func allowsParallel(_ command: NativeCommand?, shellEnvironment: [String: String]? = nil, workingDirectory: String? = nil) -> Bool {
        guard let argv = command?.argv, let executable = argv.first else { return false }
        let matches = rules.contains { $0.executable == executable && argv.dropFirst().starts(with: $0.argumentPrefix) }
        if mode == .blocklist { return !matches }
        guard Self.isShell(executable) else { return matches }
        guard let shellEnvironment, let workingDirectory else { return false }
        // Startup files/imported functions can replace otherwise static commands.
        guard ["BASH_ENV", "ENV", "ZDOTDIR"].allSatisfy({ shellEnvironment[$0] == nil }),
              !shellEnvironment.keys.contains(where: { $0.hasPrefix("BASH_FUNC_") }) else { return false }
        return allowsShell(argv, environment: shellEnvironment, cwd: workingDirectory, depth: 0)
    }
    public static func isShell(_ executable: String) -> Bool {
        // zsh always reads startup files, even with -c; do not infer its commands.
        ["/bin/sh", "/bin/bash", "/bin/zsh"].contains(executable)
    }
    private func allowsShell(_ argv: [String], environment: [String: String], cwd: String, depth: Int) -> Bool {
        guard depth < 8, argv.count == 3, argv[0] != "/bin/zsh", argv[1] == "-c",
              let commands = shellCommandList(argv[2]) else { return false }
        return commands.allSatisfy { words in
            // Bash printf can assign variables instead of printing.
            if words[0] == "printf", words.dropFirst().contains(where: { $0.hasPrefix("-v") || $0.range(of: "%[^%]*n", options: .regularExpression) != nil }) { return false }
            guard let executable = shellExecutable(words[0], environment: environment, cwd: cwd) else { return false }
            let resolved = [executable] + words.dropFirst()
            if Self.isShell(executable) { return allowsShell(resolved, environment: environment, cwd: cwd, depth: depth + 1) }
            return rules.contains { $0.executable == executable && words.dropFirst().starts(with: $0.argumentPrefix) }
        }
    }
}
