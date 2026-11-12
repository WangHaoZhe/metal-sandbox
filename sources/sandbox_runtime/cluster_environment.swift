import Foundation
import SandboxCore

public struct ClusterEnvironment: Codable {
    public let toolchain: InstalledClang
    public let privateDirectories: [String]
    public let sharedDirectories: [String]

    public init(toolchain: InstalledClang, privateDirectories: [String], sharedDirectories: [String]) {
        self.toolchain = toolchain
        self.privateDirectories = privateDirectories
        self.sharedDirectories = sharedDirectories
    }

    private static func normalized(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let value = URL(fileURLWithPath: path).standardizedFileURL.path
        return value.hasPrefix("/private/var/") ? String(value.dropFirst(8)) : value
    }

    private static func tools(_ value: InstalledClang) -> [(String, String)] {
        var tools = [("CC", value.compiler), ("CXX", value.cxxCompiler)]
        for (name, path) in [("METAL", value.metalCompiler), ("METALLIB", value.metallib),
                             ("CMAKE", value.cmake), ("NINJA", value.ninja)] {
            if let path { tools.append((name, path)) }
        }
        return tools
    }

    private static func directories(_ value: InstalledClang) -> [(String, String)] {
        var result = tools(value).map { ($0.0, URL(fileURLWithPath: $0.1).deletingLastPathComponent().path) }
        if let directory = value.buildToolsDirectory { result.append(("BUILD_TOOLS", directory)) }
        return result
    }

    private static func defaults(_ value: InstalledClang) -> [String: String] {
        var result = Dictionary(uniqueKeysWithValues: tools(value))
        result["SDKROOT"] = value.sdk
        if let directory = value.buildToolsDirectory {
            result["DEVELOPER_DIR"] = URL(fileURLWithPath: directory).deletingLastPathComponent().deletingLastPathComponent().path
        }
        return result
    }

    private func isNodePrivate(_ text: String) -> Bool {
        var candidate = text.replacingOccurrences(of: "/private/var/", with: "/var/")
        // 只豁免完整共享目录边界，保留字符串中的其他私有路径用于检查。
        for directory in sharedDirectories.sorted(by: { $0.count > $1.count }) {
            let pattern = NSRegularExpression.escapedPattern(for: Self.normalized(directory)) + "(?=/|$|[\\s'\":;])"
            candidate = candidate.replacingOccurrences(of: pattern, with: "<shared>", options: .regularExpression)
        }
        let roots = privateDirectories + Self.directories(toolchain).map(\.1)
            + [URL(fileURLWithPath: toolchain.sdk).deletingLastPathComponent().path]
        return roots.filter { !["/usr/bin", "/bin", "/usr/sbin", "/sbin"].contains($0) }
            .contains { candidate.contains(Self.normalized($0)) }
    }

    private func isCompilerSDKArgument(_ command: NativeCommand, index: Int) -> Bool {
        guard index > 0, [toolchain.compiler, toolchain.cxxCompiler].contains(command.argv[0]) else { return false }
        let value = command.argv[index]
        return (value == toolchain.sdk && ["-isysroot", "--sysroot"].contains(command.argv[index - 1]))
            || value == "--sysroot=" + toolchain.sdk || value == "-isysroot" + toolchain.sdk
    }

    public func canTransfer(_ command: NativeCommand, environment: [String: String]) -> Bool {
        let knownTools = Set(Self.tools(toolchain).map { Self.normalized($0.1) })
        for (index, argument) in command.argv.enumerated() {
            if index == 0 && knownTools.contains(Self.normalized(argument)) { continue }
            if isCompilerSDKArgument(command, index: index) { continue }
            if isNodePrivate(argument) { return false }
        }
        let defaults = Self.defaults(toolchain)
        let directories = Set(Self.directories(toolchain).map { Self.normalized($0.1) })
        for (key, value) in environment where key != "_" {
            if key == "PATH" {
                for directory in value.components(separatedBy: ":") {
                    if !directories.contains(Self.normalized(directory)), isNodePrivate(directory) { return false }
                }
            } else if let expected = defaults[key], Self.normalized(value) == Self.normalized(expected) {
                continue
            } else if isNodePrivate(value) { return false }
        }
        return true
    }

    public func prepare(_ command: NativeCommand, environment: [String: String], on target: InstalledClang) throws -> (command: NativeCommand, environment: [String: String]) {
        try command.validate()
        for directory in privateDirectories + sharedDirectories + Self.defaults(toolchain).values {
            try ClusterConfiguration.validatePath(directory)
        }
        let values = environment.merging(command.environment ?? [:]) { _, value in value }
        try EnvironmentVariables.validate(values)
        guard canTransfer(command, environment: values) else { throw SandboxError("command depends on source-node private paths") }
        var prepared = command
        prepared.environment = nil
        let targetTools = Dictionary(uniqueKeysWithValues: Self.tools(target))
        if let tool = Self.tools(toolchain).first(where: { Self.normalized($0.1) == Self.normalized(command.argv[0]) }) {
            guard let path = targetTools[tool.0] else { throw SandboxError("execution node does not provide tool: \(tool.0)") }
            prepared.argv[0] = path
        }
        for index in command.argv.indices where isCompilerSDKArgument(command, index: index) {
            let argument = command.argv[index]
            prepared.argv[index] = argument == toolchain.sdk ? target.sdk
                : (argument.hasPrefix("--sysroot=") ? "--sysroot=" : "-isysroot") + target.sdk
        }
        var result = values
        result.removeValue(forKey: "_")
        let targetDefaults = Self.defaults(target)
        for (key, expected) in Self.defaults(toolchain) {
            if let value = result[key], Self.normalized(value) == Self.normalized(expected) {
                guard let replacement = targetDefaults[key] else { throw SandboxError("execution node does not provide tool environment: \(key)") }
                result[key] = replacement
            }
        }
        if let path = result["PATH"] {
            let targetDirectories = Dictionary(uniqueKeysWithValues: Self.directories(target))
            var entries: [String] = []
            for directory in path.components(separatedBy: ":") {
                let roles = Self.directories(toolchain).filter { Self.normalized($0.1) == Self.normalized(directory) }.map(\.0)
                if roles.isEmpty { entries.append(directory); continue }
                var mapped: [String] = []
                for role in roles {
                    guard let replacement = targetDirectories[role] else { throw SandboxError("execution node does not provide PATH tool: \(role)") }
                    if !mapped.contains(replacement) { mapped.append(replacement) }
                }
                entries += mapped
            }
            result["PATH"] = entries.joined(separator: ":")
        }
        return (prepared, result)
    }
}

extension ClusterTask {
    public func prepared(on toolchain: InstalledClang) throws -> (command: NativeCommand, environment: [String: String]) {
        if let sourceEnvironment {
            guard Set(sourceEnvironment.sharedDirectories) == Set([workspace.workspace.path, workspace.home.path]) else {
                throw SandboxError("cluster environment does not match the shared workspace")
            }
            return try sourceEnvironment.prepare(command, environment: environment, on: toolchain)
        }
        let nodeKeys: Set<String> = ["PATH", "CC", "CXX", "SDKROOT", "DEVELOPER_DIR", "METAL", "METALLIB", "CMAKE", "NINJA"]
        guard nodeKeys.isDisjoint(with: environment.keys), nodeKeys.isDisjoint(with: command.environment?.keys.map { $0 } ?? []) else {
            throw SandboxError("cluster task is missing source toolchain information")
        }
        return (command, environment)
    }
}
