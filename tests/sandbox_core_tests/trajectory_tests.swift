import Foundation
import Darwin
import SandboxCore
import SandboxRuntime

private struct FixtureHarness: AgentHarness {
    let id = "fixture"
    func shell(environment: [String: String]) -> String { "/bin/sh" }
    func resources(helper: String) throws -> [String: Data] { [:] }
    func environment(resources: URL) -> [String: String] { [:] }
    func toolCommand(from event: Data) throws -> String { String(decoding: event, as: UTF8.self) }
    func toolReply(to event: Data, command: String) throws -> Data { Data(command.utf8) }
    func acceptsTrajectory(_ path: String) -> Bool { path == "fixture/events.log" }
    func trajectories(entries: (String) throws -> [WorkspaceEntry]) throws -> [TrajectorySession] {
        try entries("fixture").filter { $0.name == "events.log" && $0.kind == .file }.map {
            TrajectorySession(id: $0.path, sessionID: "test-session", source: "fixture", harness: id, modifiedAt: $0.modifiedAt)
        }
    }
}

extension RuntimeTests {
    func agentHarness() throws {
        let harness = try AgentHarnesses.selected(environment: [:])
        expectEqual(harness.id, "claude")
        expectEqual(try AgentHarnesses.selected(environment: ["METAL_SANDBOX_HARNESS": "claude"]).id, "claude")
        expectEqual(try AgentHarnesses.selected(environment: ["METAL_SANDBOX_HARNESS": "codex"]).id, "codex")
        expectThrows(try AgentHarnesses.selected(environment: ["METAL_SANDBOX_HARNESS": "unknown"]))
        expectEqual(harness.shell(environment: [:]), "/bin/bash")
        expectEqual(harness.shell(environment: ["CLAUDE_CODE_SHELL": "/bin/sh"]), "/bin/sh")
        let raw = "make && echo 'a; b' | cat\n"
        let input: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": raw, "timeout": 1234, "description": "keep me"]]
        let event = try JSONSerialization.data(withJSONObject: input)
        expectEqual(try harness.toolCommand(from: event), raw)
        let reply = try JSONSerialization.jsonObject(with: harness.toolReply(to: event, command: "annotated\n" + raw)) as! [String: Any]
        let hook = reply["hookSpecificOutput"] as! [String: Any], updated = hook["updatedInput"] as! [String: Any]
        expectEqual(hook["hookEventName"] as? String, "PreToolUse")
        expectEqual(updated["command"] as? String, "annotated\n" + raw)
        expectEqual(updated["timeout"] as? Int, 1234); expectEqual(updated["description"] as? String, "keep me")
        for invalid in ["{}", "[]", #"{"tool_name":"Read","tool_input":{"command":"ls"}}"#, #"{"tool_input":{"command":42}}"#] {
            expectThrows(try harness.toolCommand(from: Data(invalid.utf8)))
        }
        let codex = CodexHarness()
        let codexEvent = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": raw, "description": "keep me"]])
        expectEqual(try codex.toolCommand(from: codexEvent), raw)
        let codexReply = try JSONSerialization.jsonObject(with: codex.toolReply(to: codexEvent, command: raw)) as! [String: Any]
        let codexHook = codexReply["hookSpecificOutput"] as! [String: Any]
        expectEqual(codexHook["permissionDecision"] as? String, "allow")
        expectEqual((codexHook["updatedInput"] as! [String: Any])["command"] as? String, raw)
        expectEqual((codexHook["updatedInput"] as! [String: Any])["description"] as? String, "keep me")
        expectThrows(try codex.toolCommand(from: event))
        expectThrows(try codex.toolCommand(from: Data(#"{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"ls"}}"#.utf8)))
        let resources = root.appendingPathComponent("resources")
        try SafeFiles.secureDirectory(resources)
        let helper = "/application with ' quote/Contents/MacOS/sandbox-shell"
        try AgentHarnesses.installResources(at: resources, helper: helper)
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("claude_bridge.json"))) as! [String: Any]
        let hooks = settings["hooks"] as! [String: Any], pre = hooks["PreToolUse"] as! [[String: Any]]
        expectEqual(pre[0]["matcher"] as? String, "Bash")
        let command = (pre[0]["hooks"] as! [[String: Any]])[0]["command"] as! String
        expectEqual(shellCommandArguments(command), [helper, "--hook", "claude"])
        expectEqual(AgentHarnesses.environment(resources: resources)["METAL_SANDBOX_CLAUDE_SETTINGS"], resources.appendingPathComponent("claude_bridge.json").path)
        expectEqual(AgentHarnesses.environment(resources: resources)["METAL_SANDBOX_CODEX_HOOKS"], resources.appendingPathComponent("codex_bridge.json").path)
        expectEqual(codex.toolInvocation(command: "echo 'quoted'", helper: helper), #"METAL_SANDBOX_CODEX_SHELL="${METAL_SANDBOX_CODEX_SHELL:-$0}" exec '/application with '\'' quote/Contents/MacOS/sandbox-shell' 'echo '\''quoted'\'''"#)
        // A different adapter can use the common confined/cursor reader without
        // changing Host, management, scheduler or the native command schema.
        let writer = try ConfinedWorkspace(directory: root)
        try writer.write(WorkspaceFile(path: "fixture/events.log", data: Data("fixture\n".utf8)))
        let fixture = try AgentTrajectory(home: root, adapters: [FixtureHarness()])
        expectEqual(try fixture.read(session: nil, after: nil).sessions?.first?.harness, "fixture")
        let page = try fixture.read(session: "fixture/events.log", after: nil)
        expectEqual(page.harness, "fixture"); expectEqual(page.page?.data, Data("fixture\n".utf8))
        expectThrows(try AgentTrajectory(home: root).read(session: "fixture/events.log", after: nil))
    }

    func trajectory() throws {
        let reader = try AgentTrajectory(home: root)
        expectEqual(try reader.read(session: nil, after: nil).sessions?.count, 0)
        let writer = try ConfinedWorkspace(directory: root)
        let id = UUID().uuidString.lowercased()
        let path = ".claude/rollouts/\(id)/events.jsonl"
        let project = ".claude/projects/project/\(id).jsonl"
        let payload = Data(repeating: 65, count: 700_000)
        try writer.write(WorkspaceFile(path: path, data: payload))
        try writer.write(WorkspaceFile(path: project, data: Data("duplicate".utf8)))
        let list = try reader.read(session: nil, after: nil).sessions!
        expectEqual(list.count, 1); expectEqual(list[0].id, project)
        expectEqual(list[0].harness, "claude")
        expectEqual(try reader.read(session: path, after: nil).harness, "claude")
        var result = Data(), after: String?
        repeat {
            let page = try reader.read(session: path, after: after).page!
            expectTrue(page.data.count <= 256 * 1024); expectFalse(page.reset)
            result.append(page.data); after = page.nextAfter
            if page.atEnd { break }
        } while true
        expectEqual(result, payload)
        let file = root.appendingPathComponent(path)
        let append = try FileHandle(forWritingTo: file)
        try append.seekToEnd(); try append.write(contentsOf: Data("tail".utf8)); try append.close()
        let tail = try reader.read(session: path, after: after).page!
        expectEqual(tail.data, Data("tail".utf8)); expectFalse(tail.reset)
        let truncate = try FileHandle(forWritingTo: file)
        try truncate.truncate(atOffset: 0); try truncate.close()
        expectTrue(try reader.read(session: path, after: tail.nextAfter).page!.reset)
        try writer.write(WorkspaceFile(path: path, data: Data("new inode".utf8)))
        let replacement = try reader.read(session: path, after: tail.nextAfter).page!
        expectTrue(replacement.reset); expectEqual(replacement.data, Data("new inode".utf8))
        let codexPath = ".codex/sessions/2026/01/02/rollout-2026-01-02T03-04-05-\(id).jsonl"
        try writer.write(WorkspaceFile(path: codexPath, data: Data("codex\n".utf8)))
        let mixed = try reader.read(session: nil, after: nil).sessions!
        expectEqual(mixed.count, 2)
        expectEqual(mixed.first(where: { $0.harness == "codex" })?.sessionID, id)
        let codexPage = try reader.read(session: codexPath, after: nil)
        expectEqual(codexPage.harness, "codex")
        expectEqual(codexPage.page?.data, Data("codex\n".utf8))
        for invalid in [".codex/auth.json", ".codex/config.toml", ".codex/sessions/2026/01/03/rollout-2026-01-02T03-04-05-\(id).jsonl", ".codex/sessions/2026/01/02/auth.json"] {
            expectThrows(try reader.read(session: invalid, after: nil))
        }
        for invalid in [".claude/settings.json", "../secret", "/etc/passwd", ".claude/projects/../../secret"] {
            expectThrows(try reader.read(session: invalid, after: nil))
        }
        expectThrows(try reader.read(session: path, after: "-1"))
        expectThrows(try reader.read(session: path, after: "1:2:3:4:-1"))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent(project))
        expectThrows(try reader.read(session: path, after: nil))
        try FileManager.default.removeItem(at: file)
        expectEqual(link(root.appendingPathComponent(project).path, file.path), 0)
        expectThrows(try reader.read(session: path, after: nil))
        try FileManager.default.removeItem(at: file)
        expectEqual(mkfifo(file.path, 0o600), 0)
        expectThrows(try reader.read(session: path, after: nil))
        try FileManager.default.removeItem(at: file)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: root)
        expectThrows(try reader.read(session: path, after: nil))
    }
}
