import Foundation

public struct CodexConversation: HarnessConversationDecoder {
    public private(set) var entries: [ConversationEntry] = []
    private var pending = Data()
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
    private static func text(_ content: Any?) -> String {
        if let value = content as? String { return value }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    private static func fields(_ value: Any?) -> String {
        if let text = value as? String {
            guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return text }
            return fields(object)
        }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    private mutating func consume(_ data: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            add(.error, ui("无法解析的一条记录", "Unrecognized record"), ui("已跳过，后续对话仍会继续显示。", "Skipped; subsequent conversation records will still be displayed."), nil); return
        }
        guard let payload = event["payload"] as? [String: Any] else { return }
        let time = event["timestamp"] as? String
        switch event["type"] as? String {
        case "session_meta":
            add(.status, ui("会话开始", "Session started"), [payload["cli_version"] as? String, payload["model_provider"] as? String].compactMap { $0 }.joined(separator: " · "), time)
        case "event_msg":
            switch payload["type"] as? String {
            case "task_complete": add(.status, ui("会话结束", "Session ended"), "", time)
            case "turn_aborted": add(.error, ui("执行中断", "Execution interrupted"), payload["reason"] as? String ?? "", time)
            default: break
            }
        case "response_item":
            switch payload["type"] as? String {
            case "message":
                let role = payload["role"] as? String
                guard role == "user" || role == "assistant" else { return }
                let content = Self.text(payload["content"])
                if !content.isEmpty { add(role == "user" ? .user : .assistant, role == "user" ? ui("用户", "User") : "Codex", content, time) }
            case "reasoning":
                let summary = Self.text(payload["summary"])
                if !summary.isEmpty { add(.thinking, ui("思考", "Thinking"), summary, time) }
            case "function_call", "custom_tool_call":
                let name = payload["name"] as? String ?? ui("工具", "Tool")
                if let id = payload["call_id"] as? String { tools[id] = name }
                add(.tool, name, Self.fields(payload["arguments"] ?? payload["input"]), time)
            case "function_call_output", "custom_tool_call_output":
                let name = tools[payload["call_id"] as? String ?? ""] ?? ui("工具", "Tool")
                add(.result, name + ui(" · 结果", " · Result"), Self.fields(payload["output"]), time)
            default: break
            }
        default: break
        }
    }
}
