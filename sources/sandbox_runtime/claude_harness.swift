import Foundation
import SandboxCore

/// Claude-specific hook schema, shell selection and session-log layout.
public struct ClaudeHarness: AgentHarness {
    public let id = "claude"
    public init() {}
    public func shell(environment: [String: String]) -> String { environment["CLAUDE_CODE_SHELL"] ?? "/bin/bash" }
    public func toolEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        result.removeValue(forKey: "CLAUDE_CODE_TMPDIR")
        result.removeValue(forKey: "CLAUDE_CODE_SHELL_PREFIX")
        if let helper = environment["METAL_SANDBOX_SHELL_HELPER"], let path = environment["PATH"] {
            let directory = URL(fileURLWithPath: helper).deletingLastPathComponent().path
            result["PATH"] = path.components(separatedBy: ":").filter { $0 != directory }.joined(separator: ":")
        }
        return result
    }
    public func resources(helper: String) throws -> [String: Data] {
        let hook = AgentHarnesses.hookCommand(helper: helper, harness: id)
        let settings: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": hook]]]]]]
        return ["claude_bridge.json": try JSONSerialization.data(withJSONObject: settings)]
    }
    public func environment(resources: URL) -> [String: String] {
        ["METAL_SANDBOX_CLAUDE_SETTINGS": resources.appendingPathComponent("claude_bridge.json").path]
    }
    private func input(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["tool_name"] == nil || object["tool_name"] as? String == "Bash",
              let input = object["tool_input"] as? [String: Any], input["command"] is String else {
            throw SandboxError("invalid Claude Bash hook input")
        }
        return input
    }
    public func toolCommand(from event: Data) throws -> String { try input(event)["command"] as! String }
    public func toolReply(to event: Data, command: String) throws -> Data {
        var updated = try input(event); updated["command"] = command
        return try JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PreToolUse", "updatedInput": updated]])
    }
    public func acceptsTrajectory(_ path: String) -> Bool {
        guard let parts = try? ConfinedWorkspace.components(path), parts.count == 4, parts[0] == ".claude" else { return false }
        return (parts[1] == "rollouts" && UUID(uuidString: parts[2]) != nil && parts[3] == "events.jsonl")
            || (parts[1] == "projects" && parts[3].hasSuffix(".jsonl") && UUID(uuidString: String(parts[3].dropLast(6))) != nil)
    }
    public func trajectories(entries: (String) throws -> [WorkspaceEntry]) throws -> [TrajectorySession] {
        guard try entries(".").contains(where: { $0.name == ".claude" && $0.kind == .directory }) else { return [] }
        let roots = try entries(".claude")
        var found: [String: TrajectorySession] = [:]
        // Official sessions include resumed turns; captured stdout is a fallback.
        for source in ["projects", "rollouts"] where roots.contains(where: { $0.name == source && $0.kind == .directory }) {
            for directory in try entries(".claude/" + source) where directory.kind == .directory {
                if source == "rollouts", UUID(uuidString: directory.name) == nil { continue }
                for file in try entries(directory.path) where file.kind == .file && acceptsTrajectory(file.path) {
                    let sessionID = source == "rollouts" ? directory.name : String(file.name.dropLast(6))
                    if found[sessionID] == nil || (found[sessionID]?.source == source && file.modifiedAt > found[sessionID]!.modifiedAt) {
                        found[sessionID] = TrajectorySession(id: file.path, sessionID: sessionID, source: source, harness: id, modifiedAt: file.modifiedAt)
                    }
                }
            }
        }
        return Array(found.values)
    }
}
