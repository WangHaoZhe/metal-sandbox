import Foundation

/// Public CLI JSON only; the backend remains the authoritative validator.
public struct TaskPolicyDocument: Codable, Hashable {
    public struct Rule: Codable, Hashable {
        public let executable: String
        public let argumentPrefix: [String]?
    }
    public enum Mode: String, CodingKey, CaseIterable { case allowlist = "parallel", blocklist = "serial" }
    public let mode: Mode
    public let rules: [Rule]
    public init(mode: Mode, rules: [Rule] = []) { self.mode = mode; self.rules = rules }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Mode.self)
        guard values.allKeys.count == 1, let key = values.allKeys.first else {
            throw CLIError(ui("只能选择 parallel（白名单）或 serial（黑名单）其中一种", "Choose either parallel (allowlist) or serial (denylist)"))
        }
        mode = key; rules = try values.decode([Rule].self, forKey: key)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Mode.self)
        try values.encode(rules, forKey: mode)
    }
    public func json() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
    public static func parse(_ text: String) throws -> TaskPolicyDocument {
        let data = Data(text.utf8)
        guard data.count <= 128 * 1024 else { throw CLIError(ui("调度规则 JSON 不能超过 128 KiB", "Scheduling rules JSON must not exceed 128 KiB")) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 1, let key = object.keys.first, Mode(rawValue: key) != nil,
              let rules = object[key] as? [[String: Any]],
              rules.count <= 128, rules.allSatisfy({ Set($0.keys).isSubset(of: ["executable", "argumentPrefix"]) && !($0["argumentPrefix"] is NSNull) }) else {
            throw CLIError(ui("需要且只能有 parallel 或 serial 数组（最多 128 条）；每条仅支持 executable 和可选 argumentPrefix", "Provide exactly one parallel or serial array (up to 128 rules); each rule supports executable and optional argumentPrefix only"))
        }
        let policy = try JSONDecoder().decode(Self.self, from: data)
        for rule in policy.rules {
            let prefix = rule.argumentPrefix ?? []
            guard rule.executable.hasPrefix("/"), !rule.executable.contains("\0"), rule.executable.utf8.count <= 4096,
                  URL(fileURLWithPath: rule.executable).standardizedFileURL.path == rule.executable,
                  prefix.count <= 64, prefix.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 }) else {
                throw CLIError(ui("executable 必须是完整绝对路径；argumentPrefix 必须是有界字符串数组", "executable must be a full absolute path; argumentPrefix must be a bounded string array"))
            }
        }
        return policy
    }
}
