import Foundation
import SandboxCore

public struct CodexHarness: AgentHarness {
    public let id = "codex"
    public init() {}
    public func shell(environment: [String: String]) -> String {
        environment["METAL_SANDBOX_CODEX_SHELL"] ?? "/bin/bash"
    }
    public func toolEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        result.removeValue(forKey: "CODEX_CODE_MODE_HOST")
        return result
    }
    public func resources(helper: String) throws -> [String: Data] {
        let hook = AgentHarnesses.hookCommand(helper: helper, harness: id)
        let settings: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "^Bash$", "hooks": [["type": "command", "command": hook]]]]]]
        return ["codex_bridge.json": try JSONSerialization.data(withJSONObject: settings)]
    }
    public func environment(resources: URL) -> [String: String] {
        ["METAL_SANDBOX_CODEX_HOOKS": resources.appendingPathComponent("codex_bridge.json").path]
    }
    private func input(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["hook_event_name"] as? String == "PreToolUse",
              object["tool_name"] as? String == "Bash",
              let input = object["tool_input"] as? [String: Any], input["command"] is String else {
            throw SandboxError("invalid Codex Bash hook input")
        }
        return input
    }
    public func toolCommand(from event: Data) throws -> String { try input(event)["command"] as! String }
    public func toolInvocation(command: String, helper: String) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // hook 只提供命令文本；$0 来自实际执行该命令的 shell。
        return "METAL_SANDBOX_CODEX_SHELL=\"${METAL_SANDBOX_CODEX_SHELL:-$0}\" exec " + quote(helper) + " " + quote(command)
    }
    public func toolReply(to event: Data, command: String) throws -> Data {
        var updated = try input(event); updated["command"] = command
        return try JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]])
    }
    public func acceptsTrajectory(_ path: String) -> Bool {
        guard let parts = try? ConfinedWorkspace.components(path), parts.count == 6,
              parts[0] == ".codex", parts[1] == "sessions" else { return false }
        for (part, length) in zip(parts[2...4], [4, 2, 2]) {
            if part.count != length || !part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) { return false }
        }
        let name = parts[5]
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), name.count == 70,
              UUID(uuidString: String(name.dropLast(6).suffix(36))) != nil else { return false }
        return name.hasPrefix("rollout-" + parts[2...4].joined(separator: "-") + "T")
    }
    public func trajectories(entries: (String) throws -> [WorkspaceEntry]) throws -> [TrajectorySession] {
        guard try entries(".").contains(where: { $0.name == ".codex" && $0.kind == .directory }),
              try entries(".codex").contains(where: { $0.name == "sessions" && $0.kind == .directory }) else { return [] }
        var found: [TrajectorySession] = []
        for year in try entries(".codex/sessions") where year.kind == .directory {
            for month in try entries(year.path) where month.kind == .directory {
                for day in try entries(month.path) where day.kind == .directory {
                    for file in try entries(day.path) where file.kind == .file && acceptsTrajectory(file.path) {
                        let sessionID = String(file.name.dropLast(6).suffix(36))
                        found.append(TrajectorySession(id: file.path, sessionID: sessionID, source: "sessions", harness: id, modifiedAt: file.modifiedAt))
                    }
                }
            }
        }
        return found
    }
}
