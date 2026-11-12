import Foundation

public struct EnvironmentRow: Identifiable, Equatable {
    public let id = UUID()
    public var key: String
    public var value: String
    public init(key: String = "", value: String = "") { self.key = key; self.value = value }
}
public enum EnvironmentDocument {
    public static func values(_ rows: [EnvironmentRow]) throws -> [String: String] {
        var result: [String: String] = [:]
        for row in rows where !row.key.isEmpty || !row.value.isEmpty {
            guard row.key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw CLIError(ui("键名只能使用字母、数字和下划线，且不能以数字开头。", "Variable names may contain letters, digits and underscores, and must not start with a digit.")) }
            guard !["HOME", "TMPDIR", "WORKSPACE"].contains(row.key), !row.key.hasPrefix("METAL_SANDBOX_") else { throw CLIError(ui("\(row.key) 是运行时保留变量。", "\(row.key) is reserved by the runtime.")) }
            guard result[row.key] == nil else { throw CLIError(ui("重复键名：\(row.key)", "Duplicate variable: \(row.key)")) }
            guard !row.value.contains("\0") else { throw CLIError(ui("键值不能包含 NUL。", "Variable values must not contain NUL.")) }
            result[row.key] = row.value
        }
        return result
    }
    public static func rows(_ values: [String: String]) -> [EnvironmentRow] { values.keys.sorted().map { EnvironmentRow(key: $0, value: values[$0]!) } }
}

extension CLIClient {
    /// Explicit value reads bypass the activity log; never use AppModel.command.
    public func environment(id: String) async throws -> [String: String] {
        guard let values = try await sandbox(["env", id, "--show-values"]).reply().environment else { throw CLIError(ui("服务未返回环境变量。", "The service did not return environment variables.")) }
        return values
    }
    public func replaceEnvironment(id: String, values: [String: String]) async throws {
        _ = try EnvironmentDocument.values(EnvironmentDocument.rows(values))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox_environment_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("environment.json")
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = try await sandbox(["env", id, "--from", file.path]).reply()
    }
}
