import Foundation
import FrontendCore

@main struct ExecutionRegressions {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 4 else { throw CLIError("usage: execution_regressions BIN_DIR STATE_DIR OUTPUT_DIR") }
        let client = CLIClient(CLIConfiguration(directory: URL(fileURLWithPath: CommandLine.arguments[1]), stateDirectory: CommandLine.arguments[2]))
        let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw CLIError(message) }
        }
        func reply(_ args: [String]) async throws -> CLIReply { try await client.sandbox(args).reply() }
        func execute(_ id: String, _ argv: [String]) async throws -> CLIOutput {
            let job = try await client.submit(id: id, argv: argv, cwd: ".", timeout: 60)
            return try await client.sandbox(["wait", job])
        }
        try require(try await reply(["list"]).instances?.isEmpty == true, "Use an empty dedicated test service")
        let policy = output.appendingPathComponent("parallel.json")
        try Data(#"{"serial":[]}"#.utf8).write(to: policy)
        guard let a = try await reply(["create", "--count", "1", "--no_network"]).instances?.first,
              let b = try await reply(["create", "--count", "1", "--no_network", "--task-policy", policy.path]).instances?.first else {
            throw CLIError("Missing test instances")
        }

        for instance in [a, b] {
            _ = try await execute(instance.id, ["/bin/sh", "-c", "printf '#!/does/not/exist\\n' > bad_interpreter; printf 'invalid executable\\n' > bad_format; chmod +x bad_interpreter bad_format"]).checked()
            for name in ["bad_interpreter", "bad_format"] {
                let job = try await client.submit(id: instance.id, argv: ["./" + name], cwd: ".", timeout: 5)
                let waited = try await client.sandbox(["wait", job])
                try require(waited.code != 0, "Failed launch returned success")
                let raw = try await client.sandbox(["execution", job]).checked().stdout
                let record = (try JSONSerialization.jsonObject(with: raw) as! [String: Any])["execution"] as! [String: Any]
                let outcome = (record["result"] as! [String: Any])["outcome"] as! [String: Any]
                try require(record["state"] as? String == "failed" && outcome["reason"] as? String == "launchFailed"
                    && outcome["processID"] as? Int == 0 && outcome["exitCode"] == nil
                    && !(outcome["launchError"] as? String ?? "").isEmpty, "Launch failure record is incomplete")
                try require(try await reply(["status"]).status?.recoveryReason == nil, "Failed launch quarantined the node")
                _ = try await execute(instance.id, ["/bin/echo", "usable_after_launch_failure"]).checked()
            }
        }
        print("PASS: real serial/parallel launch failures preserve the node and both instances")

        let lines = [
            #"/usr/bin/printf "%s\n" hello"#,
            "/bin/echo hello # comment",
            #"/usr/bin/printf '%s\n' "a\q" "a\$b" "a\"b" "a\\b" "" '#quoted' word#suffix"#,
            #"mkdir "quoted directory""#, #"cd "quoted directory""#,
            #"/usr/bin/printf "%s\n" cwd_ok > output.txt"#, "cat output.txt", "cd ..", "exit"
        ]
        let transcript = try await console(client: client, id: a.id, lines: lines)
        let expected = "hello\nhello\na\\q\na$b\na\"b\na\\b\n\n#quoted\nword#suffix\n"
        try require(transcript.hasPrefix(expected) && transcript.contains("cwd_ok\n")
            && transcript.contains("/quoted directory\n"), "Console quoting, comments or persistent cd changed")
        try transcript.write(to: output.appendingPathComponent("console.txt"), atomically: true, encoding: .utf8)
        print("PASS: real enter preserves escapes, comments, quoted arguments and cd")

        let failed = try await client.submit(id: a.id, argv: ["/bin/sh", "-c", "while [ ! -f release_history ]; do sleep 0.1; done; exit 7"], cwd: ".", timeout: 180)
        let succeeded = try await client.submit(id: b.id, argv: ["/bin/sh", "-c", "while [ ! -f release_history ]; do sleep 0.1; done"], cwd: ".", timeout: 180)
        let cancelled = try await client.submit(id: b.id, argv: ["/bin/sleep", "180"], cwd: ".", timeout: 190)
        let reader = ExecutionHistoryReader(configuration: client.configuration) { _ in }
        await reader.refresh()
        try require(reader.snapshot.error == nil && [failed, succeeded, cancelled].allSatisfy { id in
            reader.snapshot.records.contains { $0.id == id && ["queued", "running"].contains($0.state) }
        }, "Long-running executions were not observed")
        for _ in 0..<105 { _ = try await execute(a.id, ["/usr/bin/true"]).checked() }
        let latest = try await reply(["executions", "--limit", "100"])
        try require(!(latest.executions ?? []).contains { [failed, succeeded, cancelled].contains($0.id) }, "Long tasks remain in the latest page")
        _ = try await execute(a.id, ["/usr/bin/touch", "release_history"]).checked()
        _ = try await execute(b.id, ["/usr/bin/touch", "release_history"]).checked()
        _ = try await reply(["cancel", cancelled])
        try require(try await client.sandbox(["wait", failed]).code == 7, "Expected actual exit code 7")
        _ = try await client.sandbox(["wait", succeeded]).checked()
        try require(try await client.sandbox(["wait", cancelled]).code != 0, "Cancellation returned success")
        await reader.refresh()
        try require(reader.snapshot.error == nil, reader.snapshot.error ?? "History read failed")
        for (id, state) in [(failed, "failed"), (succeeded, "succeeded"), (cancelled, "cancelled")] {
            try require(reader.snapshot.records.first { $0.id == id }?.state == state, "History did not update terminal state " + state)
        }
        print("PASS: actual history reader updates failed/succeeded/cancelled tasks older than 100 records")
        let status = try await reply(["status"]).status
        try require(status?.pendingExecutions == 0 && status?.recoveryReason == nil, "Execution cleanup incomplete")
        for instance in [a, b] {
            _ = try await reply(["stop", instance.id])
            _ = try await reply(["delete", instance.id, "--confirm"])
        }
        print("PASS: test instances deleted; service healthy")
    }

    @MainActor private static func console(client: CLIClient, id: String, lines: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var bytes = Data()
            var errors: [String] = []
            var connection: CLIConsole?
            var completed = false
            do {
                connection = try client.enter(id) { event in
                    Task { @MainActor in
                        guard !completed else { return }
                        switch event {
                        case .output(let data): bytes.append(data)
                        case .error(let message): errors.append(message)
                        case .exited(let code):
                            completed = true
                            connection = nil
                            if code == 0 && errors.isEmpty { continuation.resume(returning: String(decoding: bytes, as: UTF8.self)) }
                            else { continuation.resume(throwing: CLIError(errors.joined(separator: "\n"))) }
                        }
                    }
                }
                for line in lines { try connection!.send(line) }
            } catch { completed = true; connection?.close(); continuation.resume(throwing: error) }
        }
    }
}
