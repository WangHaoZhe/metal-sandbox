import Foundation
import FrontendCore

extension SelfTests {
    static func replicaPreparationTests() async throws {
        let script = "#!/bin/sh\nprintf '%s\\n' \"quotes ' and spaces\"\n"
        var applied: [(String, String)] = []
        let failures = await PreparationFiles.prepareReplicas(ids: ["a", "b", "c"], script: script) { id, bytes in
            applied.append((id, bytes))
            if id == "b" { throw CLIError("submission refused") }
        }
        try require(applied.map(\.0) == ["a", "b", "c"], "failed replica must not stop later replicas or retry")
        try require(applied.allSatisfy { $0.1 == script }, "every replica gets identical unmodified script bytes")
        try require(failures.count == 1 && failures[0].contains("b: submission refused"), "report failed replica")
        applied = []
        let empty = await PreparationFiles.prepareReplicas(ids: ["a"], script: " \n\t") { id, bytes in applied.append((id, bytes)) }
        try require(empty.isEmpty && applied.isEmpty, "blank preparation causes neither write nor execution")
        var order: [String] = []
        let importFailures = await PreparationFiles.prepareReplicas(ids: ["a", "b", "c"], script: script, importTask: { id in
            order.append("import " + id)
            if id == "b" { throw CLIError("bad import") }
        }) { id, _ in order.append("execute " + id) }
        try require(order == ["import a", "execute a", "import b", "import c", "execute c"], "import before execution; never execute after failed import; continue replicas")
        try require(importFailures.count == 1 && importFailures[0].contains("b: bad import"), "import failure target")
        order = []
        _ = await PreparationFiles.prepareReplicas(ids: ["a", "b"], script: "", importTask: { order.append("import " + $0) }) { id, _ in order.append("execute " + id) }
        try require(order == ["import a", "import b"], "empty script still imports the package without executing")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task_selection_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: false)
        let source = agent.appendingPathComponent("setup.sh"), instruction = agent.appendingPathComponent("instruction.md")
        try script.write(to: source, atomically: true, encoding: .utf8)
        try "task".write(to: instruction, atomically: true, encoding: .utf8)
        try require(try PreparationFiles.script(inTaskPackage: root) == script, "selected task script loaded exactly")
        try require(try String(contentsOf: source, encoding: .utf8) == script, "preview must not alter source")
        func rejects() throws {
            do { _ = try PreparationFiles.script(inTaskPackage: root) }
            catch { return }
            throw CLIError("invalid task selection accepted")
        }
        try Data().write(to: instruction); try rejects()
        try FileManager.default.removeItem(at: instruction); try rejects()
        try "task".write(to: instruction, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: instruction); try rejects()
        print("PASS replica preparation: task script preview, validation, import before execution, import-only, identical script, failure continuation and no replay")
    }
}
