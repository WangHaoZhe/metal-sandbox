import Foundation

public struct TrajectorySession: Decodable, Identifiable, Equatable {
    public let id: String
    public let sessionID: String
    public let source: String
    public let harness: String
    public let modifiedAt: Double
}
public struct TrajectoryPage: Decodable {
    public let data: Data
    public let nextAfter: String
    public let reset: Bool
    public let atEnd: Bool
}
public struct TrajectoryReply: Decodable {
    public let harness: String?
    public let sessions: [TrajectorySession]?
    public let page: TrajectoryPage?
    public let sessionsTruncated: Bool?
}

public struct ConversationEntry: Identifiable {
    public enum Kind { case user, assistant, thinking, tool, result, status, error }
    public let id: Int
    public let kind: Kind
    public let title: String
    public let text: String
    public let timestamp: String?
}

/// The UI consumes display entries, not a particular harness's JSON schema.
public protocol HarnessConversationDecoder {
    var entries: [ConversationEntry] { get }
    mutating func append(_ data: Data, reset: Bool)
}

public struct AgentConversation {
    private var harness: String?
    private var decoder: (any HarnessConversationDecoder)?
    public var entries: [ConversationEntry] { decoder?.entries ?? [] }
    public init() {}

    private static func makeDecoder(_ harness: String) throws -> any HarnessConversationDecoder {
        switch harness {
        case "claude": return ClaudeConversation()
        case "codex": return CodexConversation()
        default: throw CLIError(ui("尚未支持此 harness 的轨迹格式：\(harness)", "Unsupported harness trajectory format: \(harness)"))
        }
    }
    public mutating func append(_ data: Data, harness: String, reset: Bool = false) throws {
        if self.harness != harness || reset {
            let replacement = try Self.makeDecoder(harness)
            self.harness = harness; decoder = replacement
        }
        decoder?.append(data, reset: false)
    }
}

/// Normalizes Claude stream-json and official session JSONL into display data.
/// Partial UTF-8 / JSON lines remain buffered until the writer adds a newline.
public struct ClaudeConversation: HarnessConversationDecoder {
    public private(set) var entries: [ConversationEntry] = []
    private var pending = Data()
    private var seen = Set<String>()
    private var tools: [String: String] = [:]
    public init() {}
    public mutating func append(_ data: Data, reset: Bool = false) {
        if reset { self = Self() }
        pending.append(data)
        var start = pending.startIndex
        while let end = pending[start...].firstIndex(of: 10) {
            let line = pending[start..<end]
            if !line.isEmpty { consume(Data(line)) }
            start = pending.index(after: end)
        }
        if start != pending.startIndex { pending = Data(pending[start...]) }
    }
    private mutating func add(_ kind: ConversationEntry.Kind, _ title: String, _ text: String, _ time: String?) {
        entries.append(ConversationEntry(id: entries.count, kind: kind, title: title, text: text, timestamp: time))
    }
    private static func content(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let blocks = value as? [[String: Any]] {
            return blocks.map { block in
                if let text = block["text"] as? String { return text }
                if block["type"] as? String == "image" { return ui("[图片]", "[Image]") }
                return ui("[非文本内容]", "[Non-text content]")
            }.joined(separator: "\n")
        }
        return ""
    }
    private static func fields(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let object = value as? [String: Any] {
            return object.keys.sorted().map { "\($0)\n\(fields(object[$0]!))" }.joined(separator: "\n\n")
        }
        if let array = value as? [Any] { return array.map(fields).joined(separator: "\n") }
        return value is NSNull ? "—" : String(describing: value)
    }
    private mutating func consume(_ data: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            add(.error, ui("无法解析的一条记录", "Unrecognized record"), ui("已跳过，后续对话仍会继续显示。", "Skipped; subsequent conversation records will still be displayed."), nil); return
        }
        let type = event["type"] as? String ?? ""
        if let uuid = event["uuid"] as? String, !seen.insert(type + ":" + uuid).inserted { return }
        let time = event["timestamp"] as? String
        switch type {
        case "assistant", "user":
            guard let message = event["message"] as? [String: Any] else { return }
            if let text = message["content"] as? String {
                add(type == "user" ? .user : .assistant, type == "user" ? ui("用户", "User") : "Claude", text, time)
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    add(type == "user" ? .user : .assistant, type == "user" ? ui("用户", "User") : "Claude", block["text"] as? String ?? "", time)
                case "thinking":
                    if let text = block["thinking"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        add(.thinking, ui("思考", "Thinking"), text, time)
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? ui("工具", "Tool")
                    if let id = block["id"] as? String { tools[id] = name }
                    add(.tool, name, Self.fields(block["input"] ?? ""), time)
                case "tool_result":
                    let failed = block["is_error"] as? Bool == true
                    let name = tools[block["tool_use_id"] as? String ?? ""] ?? ui("工具", "Tool")
                    add(failed ? .error : .result, name + (failed ? ui(" · 失败", " · Failed") : ui(" · 结果", " · Result")), Self.content(block["content"]), time)
                case "image": add(.user, ui("用户", "User"), ui("[图片附件]", "[Image attachment]"), time)
                default: break
                }
            }
        case "system":
            if event["subtype"] as? String == "init" {
                add(.status, ui("会话开始", "Session started"), [event["model"] as? String, event["claude_code_version"] as? String].compactMap { $0 }.joined(separator: " · "), time)
            }
        case "result":
            let failed = event["is_error"] as? Bool == true
            var detail: [String] = []
            if let turns = event["num_turns"] as? Int { detail.append(ui("\(turns) 轮", "\(turns) turns")) }
            if let ms = event["duration_ms"] as? Double { detail.append(String(format: ui("%.1f 秒", "%.1f seconds"), ms / 1000)) }
            if failed {
                detail += (event["errors"] as? [String] ?? [])
                if let result = event["result"] as? String { detail.append(result) }
            }
            add(failed ? .error : .status, failed ? ui("会话执行失败", "Session failed") : ui("会话结束", "Session ended"), detail.joined(separator: " · "), time)
        default: break // progress, file snapshots and other non-conversation metadata
        }
    }
}
