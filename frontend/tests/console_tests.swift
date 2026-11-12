import Foundation
import FrontendCore

private final class ConsoleCapture {
    private let lock = NSLock()
    private var data = Data()
    private var code: Int32?
    func accept(_ event: CLIConsoleEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .output(let bytes): data.append(bytes)
        case .exited(let value): code = value
        case .error: break
        }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    var exitCode: Int32? { lock.lock(); defer { lock.unlock() }; return code }
}

extension SelfTests {
    static func consoleTests(root: URL) async throws {
        let bin = root.appendingPathComponent("console")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        let script = #"""
#!/usr/bin/python3
import sys,json,time,os,pathlib
args=sys.argv[1:]
(pathlib.Path(__file__).parent / ('args_' + args[-1] + '.json')).write_text(json.dumps(args))
print('READY:' + args[-1],flush=True)
for line in sys.stdin:
 line=line.rstrip('\n')
 if line=='exit':
  print('TAIL:' + args[-1],flush=True); sys.exit(7)
 if line=='large':
  os.write(1,b'x'*300000); print('LARGE_END',flush=True)
 elif line=='unicode':
  for byte in '中文🙂'.encode(): os.write(1,bytes([byte])); time.sleep(.01)
  print('UNICODE_END',flush=True)
 else:
  print('OUT:' + line,flush=True); print('ERR:' + line,file=sys.stderr,flush=True)
"""#
        let executable = bin.appendingPathComponent("sandboxctl")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = CLIClient(CLIConfiguration(directory: bin, stateDirectory: "state with spaces"))
        func wait(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<150 { if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            throw CLIError(message)
        }
        let first = ConsoleCapture(), second = ConsoleCapture()
        let a = try client.enter("a", onEvent: first.accept), b = try client.enter("b", onEvent: second.accept)
        defer { a.close(); b.close() }
        try await wait("console must stream small output without waiting for EOF") { first.text.contains("READY:a") && second.text.contains("READY:b") }
        let received = try JSONDecoder().decode([String].self, from: Data(contentsOf: bin.appendingPathComponent("args_a.json")))
        try require(received == client.configuration.sandbox(["enter", "a"]), "exact enter argv")
        let literal = "; touch \(root.path)/must_not_exist; $(echo bad)"
        try a.send(literal)
        try await wait("stdin and merged stderr") { first.text.contains("ERR:" + literal) }
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("must_not_exist").path), "console must not run a host shell")
        let configured = ConsoleCommand(line: "printf '%s' '中文 \"quote\"'", cwd: "src with spaces", timeout: 120)
        let wire = try configured.wireLine()
        let payload = try JSONSerialization.jsonObject(with: Data(wire.dropFirst(5).utf8)) as! [String: Any]
        try require(wire.hasPrefix(":run ") && payload["line"] as? String == configured.line && payload["cwd"] as? String == "src with spaces" && payload["timeout"] as? Double == 120, "console options preserve exact command and settings")
        try a.send(configured)
        try await wait("configured command uses the same enter stdin") { first.text.contains("OUT:" + wire) }
        let inherited = try ConsoleCommand(line: "pwd", cwd: "", timeout: 30).wireLine()
        let inheritedPayload = try JSONSerialization.jsonObject(with: Data(inherited.dropFirst(5).utf8)) as! [String: Any]
        try require(inheritedPayload["cwd"] == nil, "blank cwd must preserve CLI session cwd")
        _ = try ConsoleCommand(line: "pwd", cwd: ".", timeout: 0.1).wireLine()
        _ = try ConsoleCommand(line: "pwd", cwd: "", timeout: 172800).wireLine()
        for invalid in [ConsoleCommand(line: "pwd", cwd: "../escape", timeout: 30), ConsoleCommand(line: "pwd", cwd: "/tmp", timeout: 30),
                        ConsoleCommand(line: "pwd", cwd: "", timeout: .nan), ConsoleCommand(line: "pwd", cwd: "", timeout: .infinity),
                        ConsoleCommand(line: "pwd", cwd: "", timeout: 0), ConsoleCommand(line: "pwd", cwd: "", timeout: -1),
                        ConsoleCommand(line: "a\nb", cwd: "", timeout: 30), ConsoleCommand(line: " ", cwd: "", timeout: 30)] {
            do { try a.send(invalid); throw CLIError("invalid console settings accepted") }
            catch let error as CLIError { try require(error.message != "invalid console settings accepted", error.message) }
        }
        try require(ConsoleTemplate.allCases.map(\.line) == ["pwd", "cat instruction.md"], "only workspace and instruction templates remain")
        print("PASS console command settings: exact JSON, cwd inheritance, timeout validation and templates")
        for invalid in ["", "a\nb", "a\rb", "a\0b", String(repeating: "a", count: 8193)] {
            do { try a.send(invalid); throw CLIError("invalid console line accepted") }
            catch let error as CLIError { try require(error.message != "invalid console line accepted", error.message) }
        }
        try a.send("unicode"); try a.send("large")
        try await wait("large output drain and Unicode") { first.text.contains("LARGE_END") }
        try require(first.text.contains("中文🙂UNICODE_END"), "split UTF-8 preserved")
        try require(!second.text.contains("OUT:"), "console instances isolated")
        try a.send("exit")
        try await wait("exit should drain tail") { first.exitCode != nil }
        try require(first.exitCode == 7 && first.text.contains("TAIL:a"), "nonzero exit/tail retained")
        do { try a.send("late"); throw CLIError("closed session accepted write") }
        catch let error as CLIError { try require(error.message != "closed session accepted write", error.message) }
        b.close(); b.close()
        try await wait("disconnect should terminate only observer") { second.exitCode != nil }
        let again = ConsoleCapture(), c = try client.enter("a", onEvent: again.accept)
        defer { c.close() }
        try await wait("reconnect") { again.text.contains("READY:a") }
        try c.send("exit")
        for _ in 0..<40 { try? c.send("exit") }
        try await wait("broken pipe must not crash") { again.exitCode != nil }
        let missing = CLIClient(CLIConfiguration(directory: bin.appendingPathComponent("missing"), stateDirectory: "unused"))
        do { _ = try missing.enter("a", onEvent: { _ in }); throw CLIError("missing CLI accepted") }
        catch let error as CLIError { if error.message == "missing CLI accepted" { throw error } }
        catch {}
        print("PASS enter console: per-command settings, templates, argv, streaming, stdin, stderr, UTF-8, output pressure, exit, reconnect, pipe failure and isolation")
    }
    static func directoryTests() throws {
        func page(path: String = ".", entries: [[String: Any]], next: String? = nil) throws -> WorkspaceDirectory {
            var value: [String: Any] = ["path": path, "entries": entries]
            if let next { value["nextAfter"] = next }
            return try JSONDecoder().decode(WorkspaceDirectory.self, from: JSONSerialization.data(withJSONObject: value))
        }
        func entry(_ name: String, path: String? = nil, size: Int = 0) -> [String: Any] {
            ["name": name, "path": path ?? name, "kind": "file", "size": size, "modifiedAt": 123456.0]
        }
        try page(entries: [entry(".hidden"), entry("big", size: 99999999), entry("中文 file")]).validate(requestedPath: ".", after: nil)
        try page(path: "src", entries: [entry("a", path: "src/a")], next: "a").validate(requestedPath: "src", after: nil)
        let bad = try [page(path: "wrong", entries: []), page(entries: [entry("../escape")]),
            page(entries: [entry("a", path: "elsewhere")]), page(entries: [entry("b"), entry("a")]),
            page(entries: [entry("a"), entry("a")]), page(entries: [entry("a", size: -1)]),
            page(entries: [], next: "a"), page(entries: [entry("a")], next: "b"),
            page(entries: (0..<257).map { entry(String(format: "%04d", $0)) })]
        for value in bad {
            do { try value.validate(requestedPath: ".", after: nil); throw CLIError("invalid directory accepted") }
            catch let error as CLIError { try require(error.message != "invalid directory accepted", error.message) }
        }
        do { try page(entries: [entry("a")]).validate(requestedPath: ".", after: "a"); throw CLIError("invalid cursor accepted") }
        catch let error as CLIError { try require(error.message != "invalid cursor accepted", error.message) }
        for path in ["/etc", "../x", "a/./b", "a//b", "a/", "x\0"] { try require(!WorkspaceDirectory.validPath(path), "invalid path") }
        print("PASS directory DTO: metadata, nesting, pagination, ordering and invalid path/response rejection")
    }
}
