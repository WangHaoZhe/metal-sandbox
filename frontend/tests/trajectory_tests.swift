import Foundation
import FrontendCore

extension SelfTests {
    static func trajectoryTests() throws {
        let events: [[String: Any]] = [
            ["type": "system", "subtype": "init", "model": "fixture-model"],
            ["type": "user", "uuid": "prompt", "message": ["content": "题目中文"]],
            ["type": "assistant", "message": ["content": [["type": "thinking", "thinking": "先编译"], ["type": "text", "text": "开始"], ["type": "tool_use", "id": "tool1", "name": "Bash", "input": ["command": "make -j4"]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "tool1", "is_error": true, "content": [["type": "text", "text": "compiler error"]]]]]],
            ["type": "result", "is_error": false, "num_turns": 2, "duration_ms": 3000],
            ["type": "file-history-snapshot", "snapshot": ["ignored": true]],
            ["type": "user", "uuid": "prompt", "message": ["content": "duplicate"]]
        ]
        var bytes = Data()
        for event in events { bytes.append(try JSONSerialization.data(withJSONObject: event)); bytes.append(10) }
        var conversation = AgentConversation()
        // One-byte chunks exercise split UTF-8 and incomplete JSON lines.
        for byte in bytes { try conversation.append(Data([byte]), harness: "claude") }
        try require(conversation.entries.count == 7, "normalized entries and duplicate/metadata filtering")
        try require(conversation.entries[1].text == "题目中文", "UTF-8 preserved across chunks")
        try require(conversation.entries[2].kind == .thinking, "thinking is separately collapsible")
        try require(conversation.entries[4].text == "command\nmake -j4", "tool input displayed as fields, not JSON")
        try require(conversation.entries[5].title == "Bash · 失败" && conversation.entries[5].text == "compiler error", "linked tool error")
        try require(conversation.entries.last?.title == "会话结束", "exit is not a correctness verdict")
        try conversation.append(Data(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""}]}}"#.utf8) + Data([10]), harness: "claude")
        try require(conversation.entries.count == 7, "empty thinking must not create a blank card")
        try conversation.append(Data("invalid\n".utf8), harness: "claude")
        try require(conversation.entries.last?.kind == .error, "malformed record is a visible warning")
        try conversation.append(Data("{\"type\":\"user\",\"message\":{\"content\":\"partial\"}}".utf8), harness: "claude", reset: true)
        try require(conversation.entries.isEmpty, "reset discards old session and incomplete line waits")
        try conversation.append(Data([10]), harness: "claude")
        try require(conversation.entries.first?.text == "partial", "later newline completes record")
        do {
            try conversation.append(Data(), harness: "unknown")
            try require(false, "unimplemented harness must not silently use the Claude decoder")
        } catch let error as CLIError { try require(error.localizedDescription.contains("unknown"), "unsupported harness is explicit") }
        try require(conversation.entries.first?.text == "partial", "failed decoder selection must not erase the prior conversation")
        let codexEvents: [[String: Any]] = [
            ["type": "session_meta", "payload": ["cli_version": "0.162.1"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "运行测试"]]]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "运行测试"]],
            ["type": "response_item", "payload": ["type": "reasoning", "summary": [["type": "summary_text", "text": "准备命令"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "开始测试"]]]],
            ["type": "response_item", "payload": ["type": "function_call", "name": "exec_command", "call_id": "shell1", "arguments": "{\"cmd\":\"printf ok\"}"]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "shell1", "output": "ok"]],
            ["type": "event_msg", "payload": ["type": "task_complete"]]
        ]
        var codexBytes = Data()
        for event in codexEvents { codexBytes.append(try JSONSerialization.data(withJSONObject: event)); codexBytes.append(10) }
        for byte in codexBytes { try conversation.append(Data([byte]), harness: "codex") }
        try require(conversation.entries.count == 7, "Codex normalizes its own event schema and avoids event-message duplicates")
        try require(conversation.entries[1].text == "运行测试", "Codex preserves incremental UTF-8")
        try require(conversation.entries[2].kind == .thinking, "Codex reasoning summary")
        try require(conversation.entries[5].title == "exec_command · 结果" && conversation.entries[5].text == "ok", "Codex links tool output")
        try conversation.append(Data(), harness: "codex", reset: true)
        try require(conversation.entries.isEmpty, "Codex session reset")
        let reply = try JSONDecoder().decode(CLIReply.self, from: Data(#"{"ok":true,"trajectory":{"harness":"claude","sessions":[{"id":"log","sessionID":"session","source":"projects","harness":"claude","modifiedAt":0}],"page":{"data":"eA==","nextAfter":"1:2:3:4:1","reset":false,"atEnd":true}}}"#.utf8))
        try require(reply.trajectory?.page?.data == Data("x".utf8), "public CLI trajectory DTO")
        try require(reply.trajectory?.harness == "claude" && reply.trajectory?.sessions?.first?.harness == "claude", "trajectory provider identity reaches the frontend")
        print("PASS trajectory: incremental UTF-8, roles, thinking, linked tools/errors, metadata/dedup, partial/reset, tolerant parsing and CLI DTO")
    }
}
