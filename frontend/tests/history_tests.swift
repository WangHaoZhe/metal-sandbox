import Foundation
import FrontendCore

extension SelfTests {
    static func historyTests(root: URL) throws {
        let config = CLIConfiguration(directory: root, stateDirectory: "/state")
        func brief(_ state: String) throws -> ExecutionBrief {
            try JSONDecoder().decode(ExecutionBrief.self, from: JSONSerialization.data(withJSONObject: ["id":"exec-test","instanceID":"sbx-test","state":state,"createdAt":1000,"program":"/bin/sh"]))
        }
        var records: [Activity] = []
        Activity.merge([try brief("running"), try brief("running")], into: &records, configuration: config)
        try require(records.count == 1 && records[0].waiting && records[0].status == "执行中", "pending/history duplicate merge")
        let stableID = records[0].id
        Activity.merge([try brief("succeeded")], into: &records, configuration: config)
        try require(records[0].id == stableID && !records[0].waiting && records[0].code == 0, "same row changes state")
        try require(records[0].sandboxIDs == ["sbx-test"] && !records[0].hasCommandDetails, "attribution and no fabricated full command")
        records = [Activity(title: "GUI submit", command: "real command", executionID: "exec-test", configuration: config)]
        Activity.merge([try brief("running")], into: &records, configuration: config)
        try require(records.count == 1 && records[0].command == "real command", "GUI and CLI represent one execution")
        let other = CLIConfiguration(directory: root, stateDirectory: "/other")
        Activity.merge([try brief("running")], into: &records, configuration: other)
        try require(records.count == 2, "do not merge separate services")
        let verification = try JSONDecoder().decode(ExecutionBrief.self, from: Data("{\"id\":\"verify\",\"instanceID\":\"sbx-test\",\"state\":\"succeeded\",\"createdAt\":1000,\"program\":\"/bin/bash\",\"verification\":true}".utf8))
        Activity.merge([verification], into: &records, configuration: config)
        try require(records.contains { $0.title == "验收 · tests/test.sh" }, "backend verification history title")
        try require(Activity.targets(["verify", "sbx-test"]) == ["sbx-test"], "verification attribution")
        try require(Activity.targets(["snapshot", "sbx-test"]) == ["sbx-test"], "explicit snapshot attribution")
        let folder = root.appendingPathComponent("task with spaces")
        let args = try Verification.arguments(id: "sbx-test", taskFolder: folder, timeout: 90)
        try require(args == ["verify", "sbx-test", "--timeout", "90.0", "--detach", "--from", folder.path], "verification uses public CLI and preserves paths")
        let detail = try JSONDecoder().decode(ExecutionSummary.self, from: Data("{\"id\":\"verify\",\"state\":\"succeeded\",\"result\":{\"stdout\":\"\",\"stderr\":\"\",\"outcome\":{\"exitCode\":0,\"reason\":\"exited\"}}}".utf8))
        try require(Verification.status(detail) == "通过", "successful verifier result")
        let cancelled = try JSONDecoder().decode(ExecutionSummary.self, from: Data("{\"id\":\"verify\",\"state\":\"cancelled\"}".utf8))
        try require(Verification.status(cancelled) == "已取消", "cancelled verifier is not a pass")
        print("PASS backend history: CLI/GUI deduplication, stable selection, state updates, attribution and connection isolation")
    }
}
