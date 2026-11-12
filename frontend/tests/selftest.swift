import Foundation
import FrontendCore

@main struct SelfTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw CLIError(message) }
    }
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.count == 6, ["--live", "--start-service"].contains(args[0]), args[2] == "--state-dir", args[4] == "--output" {
                if args[0] == "--live" { try await live(bin: URL(fileURLWithPath: args[1]), state: args[3], output: URL(fileURLWithPath: args[5])) }
                else { try await start(bin: URL(fileURLWithPath: args[1]), state: args[3], output: URL(fileURLWithPath: args[5])) }
            } else if args.isEmpty { try await mock() }
            else { throw CLIError("Usage: frontend-selftest [--live BIN_DIR --state-dir STATE --output NEW_DIR]") }
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func start(bin: URL, state: String, output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let client = CLIClient(CLIConfiguration(directory: bin, stateDirectory: state))
        let service = try client.startService(log: output.appendingPathComponent("service.log"))
        for _ in 0..<100 {
            guard service.isRunning else { throw CLIError("packaged service exited") }
            if let reply = try? await client.sandbox(["status"], timeout: 2).reply(), reply.status != nil {
                print("Started service PID \(service.processIdentifier); the launching process will now exit without stopping the daemon.")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CLIError("startup not confirmed; preserve service log and inspect")
    }
    static func mock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frontend_tests_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = #"""
#!/usr/bin/python3
import sys,json,pathlib,time
args=sys.argv[1:]
(pathlib.Path(__file__).parent/'received.json').write_text(json.dumps(args))
with (pathlib.Path(__file__).parent/'calls.jsonl').open('a') as log: log.write(json.dumps(args)+'\n')
if 'fail' in args:
 print('fixture error',file=sys.stderr); sys.exit(7)
if 'invalid_ownership' in args:
 print('incomplete physical ownership journal; deletion refused',file=sys.stderr); sys.exit(1)
if 'rejected' in args:
 print(json.dumps({'ok':False,'error':'fixture service rejection'})); sys.exit(0)
if 'sleep' in args: time.sleep(10)
if 'large' in args:
 print('o'*200000); print('e'*200000,file=sys.stderr); sys.exit(0)
if 'malformed' in args: print('not json'); sys.exit(0)
if any(a.startswith('prep_') for a in args):
 iid=next(a for a in args if a.startswith('prep_'))
 root=pathlib.Path(__file__).parent/iid
 if 'ls' in args:
  names=sorted(p.name for p in root.iterdir())
  after=args[args.index('--after')+1] if '--after' in args else ''
  names=[n for n in names if n>after]
  page=names[:1]
  entries=[{'name':n,'path':n,'kind':'file','size':(root/n).stat().st_size,'modifiedAt':0} for n in page]
  print(json.dumps({'ok':True,'directory':{'path':'.','entries':entries,'nextAfter':page[-1] if len(names)>1 else None}})); sys.exit(0)
 if 'read' in args:
  pathlib.Path(args[args.index('--out')+1]).write_bytes((root/args[args.index('read')+2]).read_bytes())
  print(json.dumps({'ok':True})); sys.exit(0)
if 'exec' in args: print(json.dumps({'ok':True,'execution':{'id':'fixture_execution','state':'queued'}}))
else: print(json.dumps({'ok':True,'extraFutureField':123,'instances':[]}))
"""#
        let executable = root.appendingPathComponent("sandboxctl")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = CLIClient(CLIConfiguration(directory: root, stateDirectory: root.appendingPathComponent("state with spaces").path))
        let malicious = "; touch \(root.path)/must_not_exist; $(echo bad)\n'space'"
        let id = try await client.submit(id: "sbx-test", argv: ["/bin/echo", malicious], cwd: "a b", timeout: 12)
        try require(id == "fixture_execution", "execution ID")
        let received = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("received.json")))
        try require(received == client.configuration.sandbox(["exec","sbx-test","--cwd","a b","--timeout","12.0","--detach","--","/bin/echo",malicious]), "argv must remain exact, never shell-expanded")
        _ = try await client.sandbox(["rename", "sbx-test", ""]).checked()
        let clearName = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("received.json")))
        try require(clearName == client.configuration.sandbox(["rename", "sbx-test", ""]), "clearing a name must preserve the empty CLI argument")
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("must_not_exist").path), "shell injection marker")
        _ = try await client.submit(id: "sbx-test", argv: ["/bin/sh", "./setup.sh"], cwd: ".", timeout: 7200, session: true)
        let sessionArgs = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("received.json")))
        try require(sessionArgs == client.configuration.sandbox(["exec", "sbx-test", "--cwd", ".", "--timeout", "7200.0", "--detach", "--session", "--", "/bin/sh", "./setup.sh"]), "preparation session is a public CLI option, not frontend scheduling")
        print("PASS exact CLI argv, state path, detached execution ID, preparation session and no host shell")
        let reply = try await client.sandbox(["list"]).reply()
        try require(reply.ok && reply.instances?.count == 0, "tolerant reply")
        let instanceJSON: [String: Any] = ["id": "sbx-test", "state": "active", "createdAt": 0, "revisions": 1]
        var counted = instanceJSON
        counted["pendingExecutions"] = 7
        counted["executionCounts"] = ["parallelRunning": 2, "parallelWaiting": 1, "serialRunning": 1, "serialWaiting": 3]
        let countedInstance = try JSONDecoder().decode(SandboxInstance.self, from: JSONSerialization.data(withJSONObject: counted))
        try require(countedInstance.executionCounts?.parallelRunning == 2 && countedInstance.executionCounts?.parallelWaiting == 1
            && countedInstance.executionCounts?.serialRunning == 1 && countedInstance.executionCounts?.serialWaiting == 3, "four backend counters decoded independently")
        for count in [nil, 0, 2] as [Int?] {
            var json = instanceJSON
            if let count { json["pendingExecutions"] = count }
            let instance = try JSONDecoder().decode(SandboxInstance.self, from: JSONSerialization.data(withJSONObject: json))
            try require(instance.pendingExecutions == count, "per-instance pending count; old services remain unknown, not zero")
        }
        let failed = try await client.sandbox(["fail"])
        try require(failed.code == 7 && failed.errorText.contains("fixture error"), "exit code/stderr propagation")
        do { _ = try await client.sandbox(["malformed"]).reply(); throw CLIError("invalid JSON accepted") }
        catch let error as CLIError { if error.message == "invalid JSON accepted" { throw error } }
        catch {}
        print("PASS JSON contract, nonzero exit and invalid response handling")
        let large = try await client.sandbox(["large"])
        try require(large.stdout.count > 200000 && large.stderr.count > 200000, "large stdout/stderr without pipe deadlock")
        async let first = client.sandbox(["list"])
        async let second = client.sandbox(["fail"])
        let outputs = try await (first, second)
        try require(outputs.0.code == 0 && outputs.1.code == 7, "concurrent clients isolated")
        print("PASS bounded output capture and concurrent CLI isolation")
        do { _ = try await client.sandbox(["sleep"], timeout: 0.1); throw CLIError("timeout not enforced") }
        catch let error as CLIError { try require(error.message.contains(ui("结果未知", "result is unknown")), "timeout must not claim cancellation/success") }
        print("PASS observer timeout reports unknown outcome without retry")
        _ = try await client.sandbox(["list"], timeout: .greatestFiniteMagnitude)
        _ = try await client.submit(id: "sbx-test", argv: ["/bin/echo"], cwd: ".", timeout: 172800)
        try await batchTests(client: client, root: root)
        try await revealTests(client: client, root: root)
        try await consoleTests(root: root)
        try terminalLauncherTests(root: root)
        try directoryTests()
        try await previewTests(client: client, root: root)
        try taskPolicyTests()
        try await preparationTests(client: client, root: root)
        try await replicaPreparationTests()
        try environmentTests()
        try historyTests(root: root)
        try trajectoryTests()
        try activityTests(root: root)
        print("21/21 frontend unit groups passed")
    }

    @MainActor static func previewTests(client: CLIClient, root: URL) async throws {
        let fixture = root.appendingPathComponent("prep_preview")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        let pdf = Data("%PDF-1.4\nASCII PDF fixture\n%%EOF".utf8)
        let cases: [(String, Data, Bool)] = [
            ("hello.txt", Data("read only\n".utf8), true),
            ("kernel.metal", Data("kernel void main0() {}".utf8), true),
            ("README", Data("plain text without extension".utf8), true),
            ("image.png", Data([137, 80, 78, 71, 0, 13, 10]), false),
            ("document.pdf", pdf, false),
            ("formatted.rtf", Data("{\\rtf1 formatted}".utf8), false),
            ("binary.unknown", Data([0, 255, 1, 2]), false)
        ]
        for (name, bytes, textual) in cases {
            try bytes.write(to: fixture.appendingPathComponent(name))
            let preview = try WorkspacePreview(name: name)
            let folder = preview.file.deletingLastPathComponent()
            try require(preview.file.lastPathComponent == name, "preview preserves extension and name")
            _ = try await client.sandbox(["read", "prep_preview", name, "--out", preview.file.path]).checked()
            try preview.prepare()
            try require((preview.text != nil) == textual, "text fallback versus native preview: " + name)
            try require((try FileManager.default.attributesOfItem(atPath: preview.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o400, "preview copy is read-only")
            try require(try Data(contentsOf: fixture.appendingPathComponent(name)) == bytes, "source remains unchanged")
            preview.close()
            try require(!FileManager.default.fileExists(atPath: folder.path), "explicit preview cleanup")
        }
        for name in ["../file.pdf", "a/file.pdf", "", "/file.pdf", "a\0b"] {
            do { _ = try WorkspacePreview(name: name); throw CLIError("unsafe preview name accepted") }
            catch let error as CLIError { try require(error.message == ui("无效预览文件名", "Invalid preview filename"), "invalid preview filename rejected") }
        }
        let link = try WorkspacePreview(name: "link.txt")
        try FileManager.default.createSymbolicLink(at: link.file, withDestinationURL: fixture.appendingPathComponent("hello.txt"))
        do { try link.prepare(); throw CLIError("symbolic preview accepted") }
        catch let error as CLIError { try require(error.message == ui("预览副本不是普通文件", "Preview copy is not a regular file"), "preview rejects symbolic links") }
        link.close()
        let limit = 4 * 1024 * 1024
        let large = try WorkspacePreview(name: "large.txt")
        try (Data(repeating: 97, count: limit - 1) + Data("💙tail".utf8)).write(to: large.file)
        try large.prepare()
        try require(large.textTruncated && large.text?.utf8.count == limit - 1, "large text preview ends on a UTF-8 boundary")
        large.close()
        var location: URL?
        do { let preview = try WorkspacePreview(name: "cleanup.bin"); location = preview.file.deletingLastPathComponent() }
        try require(!FileManager.default.fileExists(atPath: location!.path), "preview lease cleans up on release")
        print("PASS read-only preview copies: CLI read, filenames, formats, UTF-8 bounds, symlinks and cleanup")
    }

    static func activityTests(root: URL) throws {
        let a = "sbx-a", b = "sbx-ab"
        let config = CLIConfiguration(directory: root, stateDirectory: "state")
        let other = CLIConfiguration(directory: root, stateDirectory: "other")
        var failed = Activity(title: "write", command: "write", sandboxIDs: Activity.targets(["write", a, b]))
        failed.code = 1
        let execution = Activity(title: "exec", command: "exec", executionID: "job", sandboxIDs: [b], configuration: config, waiting: true)
        let shared = Activity(title: "create", command: "create", sandboxIDs: [a, b])
        let global = Activity(title: "service", command: "shutdown")
        let records = [failed, execution, shared, global]
        try require(records.filter { ActivityFilter.all.includes($0) }.count == 4, "all records")
        try require(records.filter { ActivityFilter.sandbox(a).includes($0) }.map(\.id) == [failed.id, shared.id], "exact ID match, failed writes and multi-instance creation")
        try require(records.filter { ActivityFilter.sandbox(b).includes($0) }.map(\.id) == [execution.id, shared.id], "running executions stay classified")
        try require(records.filter { ActivityFilter.unassigned.includes($0) }.map(\.id) == [global.id], "global records isolated")
        try require(!ActivityFilter.sandbox("sbx-missing").includes(global), "empty filter must not show another record")
        try require(ActivityFilter.sandboxIDs(in: records, currentIDs: [b, "sbx-new"]) == [a, b, "sbx-new"], "deleted IDs retained, current IDs included and deduplicated")
        try require(Activity.targets(executionID: "job", configuration: config, in: records) == [b], "manual wait keeps known execution owner")
        try require(Activity.targets(executionID: "job", configuration: other, in: records).isEmpty, "do not mix connection histories")
        try require(Activity.targets(executionID: "unknown", configuration: config, in: records).isEmpty, "unknown wait stays unassigned")
        try require(Activity.targets(["stop", "--all"]).isEmpty, "stop-all is a global operation")
        try require(Activity.targets(["cancel", "job"]).isEmpty, "execution ID is not a sandbox ID")
        try require(Activity.targets(["reveal-containers", "local.metal-sandbox.instance-x"]).isEmpty, "physical ID is not a logical ID")
        try require(Activity.targets([]).isEmpty, "missing command")
        let instance: (String) -> [String: Any] = { ["id": $0, "state": "active", "createdAt": 0, "revisions": 1] }
        let created = try JSONDecoder().decode(CLIReply.self, from: JSONSerialization.data(withJSONObject: ["ok": true, "instances": [instance(a), instance(b)]]))
        try require(Activity.targets(["create", "--count", "2"], reply: created) == [a, b], "associate all created IDs from public reply")
        try require(Activity.targets(["list"], reply: created).isEmpty, "listing does not claim every sandbox")
        let restored = try JSONDecoder().decode(CLIReply.self, from: JSONSerialization.data(withJSONObject: ["ok": true, "instance": instance(b)]))
        try require(Activity.targets(["restore", a], reply: restored) == [a, b], "clone belongs to source and destination")
        let cancelled = try JSONDecoder().decode(CLIReply.self, from: Data(#"{"ok":true,"execution":{"id":"job","state":"cancelled","instanceID":"sbx-a"}}"#.utf8))
        try require(Activity.targets(["cancel", "job"], reply: cancelled) == [a], "cancel resolves from public execution metadata")
        let brief = try JSONDecoder().decode(ExecutionBrief.self, from: Data(#"{"id":"job","instanceID":"sbx-ab","state":"running","createdAt":0,"program":"/bin/sh"}"#.utf8))
        var merged = records
        Activity.merge([brief], into: &merged, configuration: config)
        let unchanged = merged
        Activity.merge([brief], into: &merged, configuration: config)
        try require(merged == unchanged, "identical backend history keeps activity IDs and values unchanged")
        var edited = merged[0]; edited.output += "new output"
        try require(edited != merged[0], "real activity updates remain detectable")
        print("PASS activity filters: exact IDs, failures, running tasks, global/empty groups, deleted IDs, create/clone, known waits and connection isolation")
    }

    static func preparationTests(client: CLIClient, root: URL) async throws {
        for id in ["prep_empty", "prep_a", "prep_b"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(id), withIntermediateDirectories: false)
        }
        let empty = try await PreparationFiles.read(id: "prep_empty", client: client)
        try require(empty == PreparationFiles(), "empty workspace must not invent a script or prompt")
        let a = PreparationFiles(script: "#!/bin/sh\nprintf actual_a\\n\n", instruction: "task A")
        let b = PreparationFiles(script: "#!/bin/sh\nprintf actual_b\\n\n", instruction: "task B")
        for (id, value) in [("prep_a", a), ("prep_b", b)] {
            try await value.save { path, text in
                try text.write(to: root.appendingPathComponent(id).appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            let actual = try await PreparationFiles.read(id: id, client: client)
            try require(actual == value, "read exact saved files through CLI, including paginated listing")
        }
        var written: [String] = []
        do {
            try await a.save { path, _ in written.append(path); throw CLIError("fixture write failure") }
            throw CLIError("preparation ignored write failure")
        } catch let error as CLIError { try require(error.message == "fixture write failure", "save propagates failure") }
        try require(written == ["setup.sh"], "do not proceed after a failed write")
        try require(a != b, "separate sandbox preparation contents")
        try await b.save { path, text in
            try text.write(to: root.appendingPathComponent("prep_a").appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let replaced = try await PreparationFiles.read(id: "prep_a", client: client)
        try require(replaced == b, "replacing a task reads its new setup, not the previous script")
        try FileManager.default.removeItem(at: root.appendingPathComponent("prep_a/setup.sh"))
        let noScript = try await PreparationFiles.read(id: "prep_a", client: client)
        try require(noScript.script == nil && noScript.instruction == b.instruction, "missing setup must not fall back to another task or bundled harness")
        print("PASS preparation files: empty state, exact CLI reload, task replacement, missing setup, pagination, instance separation and failed-write stop")
    }

    static func taskPolicyTests() throws {
        let json = #"{"parallel":[{"executable":"/bin/cat"},{"executable":"/tools/cmake","argumentPrefix":["--build"]}]}"#
        let policy = try TaskPolicyDocument.parse(json)
        try require(TaskPolicyDocument.parse(policy.json()) == policy, "policy JSON round trip")
        try require(policy.mode == .allowlist, "parallel JSON selects allowlist")
        try require(TaskPolicyDocument.parse(#"{"parallel":[]}"#).rules.isEmpty, "empty allowlist is explicit, not missing")
        let blocklist = try TaskPolicyDocument.parse(#"{"serial":[{"executable":"/bin/cat","argumentPrefix":["file"]}]}"#)
        try require(blocklist.mode == .blocklist && blocklist.rules.count == 1, "blocklist decoded")
        try require(TaskPolicyDocument.parse(blocklist.json()) == blocklist, "blocklist JSON round trip")
        let emptyBlocklist = try TaskPolicyDocument.parse(TaskPolicyDocument(mode: .blocklist).json())
        try require(emptyBlocklist.mode == .blocklist && emptyBlocklist.rules.isEmpty, "empty blocklist remains distinct")
        for invalid in ["", "null", #"{"parallel":"all"}"#, #"{"parallel":[],"typo":1}"#,
                        #"{"parallel":[{"executable":"cat"}]}"#, #"{"parallel":[{"executable":"/bin/../bin/cat"}]}"#,
                        #"{"parallel":[{"executable":"/bin/cat","argumentprefix":["--help"]}]}"#,
                        #"{"parallel":[{"executable":"/bin/cat","argumentPrefix":null}]}"#,
                        #"{"serial":[],"parallel":[]}"#, #"{"serial":null}"#, #"{"serial":[],"typo":1}"#,
                        #"{"serial":[{"executable":"cat"}]}"#, #"{"serial":[{"executable":"/bin/cat","argumentPrefix":null}]}"#] {
            do { _ = try TaskPolicyDocument.parse(invalid); throw CLIError("invalid policy accepted") }
            catch let error as CLIError { try require(error.message != "invalid policy accepted", invalid) }
            catch {}
        }
        let unnamed = Data(#"{"id":"sbx-old","state":"stopped","createdAt":0,"revisions":1}"#.utf8)
        try require(JSONDecoder().decode(SandboxInstance.self, from: unnamed).sidebarTitle == "sbx-old", "unnamed instance uses ID prefix")
        let current = Data((#"{"id":"sbx-new","state":"active","createdAt":0,"revisions":1,"taskPolicy": "# + json + "}").utf8)
        try require(JSONDecoder().decode(SandboxInstance.self, from: current).taskPolicy == policy, "per-instance policy decoded")
        let named = Data(#"{"id":"sbx-12345678-rest","name":"毒蘑菇 (1)","state":"stopped","createdAt":0,"revisions":1}"#.utf8)
        let namedInstance = try JSONDecoder().decode(SandboxInstance.self, from: named)
        try require(namedInstance.sidebarTitle == "毒蘑菇 (1)" && namedInstance.id == "sbx-12345678-rest", "sidebar name never replaces identity")
        for replacement in ["null", "\"\""] {
            let cleared = Data(String(decoding: named, as: UTF8.self).replacingOccurrences(of: "\"毒蘑菇 (1)\"", with: replacement).utf8)
            try require(JSONDecoder().decode(SandboxInstance.self, from: cleared).sidebarTitle == "sbx-12345678", "clearing name restores the original ID prefix")
        }
        print("PASS task-policy JSON: validation, exact fields, empty policy, display round trip and optional fields")
    }

    static func terminalLauncherTests(root: URL) throws {
        let directory = root.appendingPathComponent("tools ' quotes ; $()")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let executable = directory.appendingPathComponent("sandboxctl")
        try FileManager.default.copyItem(at: root.appendingPathComponent("sandboxctl"), to: executable)
        let client = CLIClient(CLIConfiguration(directory: directory, stateDirectory: "state ' ; $(touch must_not_exist)\nspace"))
        let id = "sbx-' ; $(echo injected)"
        let file = try client.terminalLauncher(id)
        for path in [file, file.deletingLastPathComponent()] {
            let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
            try require(mode?.intValue == 0o700, "private executable Terminal launcher")
        }
        let process = Process()
        process.executableURL = file
        process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "launcher executes CLI")
        let received = try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("received.json")))
        try require(received == client.configuration.sandbox(["enter", id]), "Terminal forwards exact quoted CLI/state/instance argv")
        try require(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path), "one-shot launcher removes only its private directory")
        do {
            _ = try CLIClient(CLIConfiguration(directory: root.appendingPathComponent("missing"), stateDirectory: "unused")).terminalLauncher(id)
            throw CLIError("missing CLI accepted")
        } catch let error as CLIError { try require(error.message != "missing CLI accepted", "reject missing CLI") }
        print("PASS Terminal launcher: exact argv with shell metacharacters, private permissions, self-cleanup and missing CLI")
    }

    static func revealTests(client: CLIClient, root: URL) async throws {
        let a = "local.metal-sandbox.instance-" + UUID().uuidString.lowercased()
        let b = "local.metal-sandbox.instance-" + UUID().uuidString.lowercased()
        func reply(state: String = "deleted", ok: Bool = true, warning: Bool = true,
                   owned: [String]? = nil, physical: String? = nil) throws -> CLIReply {
            var instance: [String: Any] = ["id": "sbx-test", "state": state, "createdAt": 0, "revisions": 2]
            if let owned { instance["ownedBundleIDs"] = owned }
            if let physical { instance["physical"] = ["bundleID": physical, "pid": 0, "home": "/ignored", "workspace": "/ignored", "bundle": "/ignored"] }
            var json: [String: Any] = ["ok": ok, "instance": instance]
            if warning { json["warnings"] = ["remaining shell"] }
            return try JSONDecoder().decode(CLIReply.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let single = DeletedContainerReveal(replies: [try reply(owned: [a])])
        try require(single.bundleIDs == [a], "reveal confirmed deletion identity")
        let multiple = DeletedContainerReveal(replies: [try reply(owned: [a, b, a]), try reply(owned: [b])])
        try require(multiple.bundleIDs == [a, b].sorted(), "batch reveal deduplicates registered identities")
        let ignored = DeletedContainerReveal(replies: [try reply(state: "active", owned: [a]),
            try reply(state: "delete-failed", owned: [a]), try reply(ok: false, owned: [a]),
            try reply(warning: false, owned: [a]), try reply(), try reply(physical: a), try reply(owned: [], physical: a)])
        try require(ignored.bundleIDs.isEmpty, "never reveal failed/active/unconfirmed/absent targets or infer paths from warning text")
        _ = try await client.sandbox(multiple.arguments).checked()
        let actual = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("received.json")))
        try require(actual == client.configuration.sandbox(["reveal-containers"] + [a, b].sorted()), "Finder action uses only exact public CLI arguments")
        let selection = try [reply(state: "active", physical: a), reply(state: "stopped", physical: b),
                             reply(state: "failed"), reply(state: "stopped", physical: a)].compactMap(\.instance)
        try require(selection.containerBundleIDs == [a, b].sorted(), "multi-selection reveals current containers regardless of lifecycle, skips missing identities and deduplicates")
        try require(Array(selection.prefix(1)).containerBundleIDs == [a], "single-selection remains supported")
        try require([SandboxInstance]().containerBundleIDs.isEmpty && [selection[2]].containerBundleIDs.isEmpty, "empty or unallocated selection disables reveal")
        let log = root.appendingPathComponent("calls.jsonl")
        let before = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count
        _ = try await client.sandbox(["reveal-containers"] + selection.containerBundleIDs).checked()
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        try require(calls.count == before + 1, "selected containers use one CLI call, without starting or executing an instance")
        let selectedArgs = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("received.json")))
        try require(selectedArgs == client.configuration.sandbox(["reveal-containers"] + [a, b].sorted()), "all selected container IDs reach the CLI together")
        let result = try JSONDecoder().decode(CLIReply.self, from: Data(#"{"ok":true,"finderRequested":false,"warnings":["missing"],"paths":[],"missing":[]}"#.utf8))
        try require(result.finderRequested == false && result.warnings == ["missing"], "missing containers do not claim Finder was opened")
        print("PASS container reveal: single/multi-selection, missing identities, one CLI call, deletion provenance and missing-directory feedback")
    }

    @MainActor static func batchTests(client: CLIClient, root: URL) async throws {
        var selection = SidebarSelection()
        let visible = ["a", "b", "c"]
        selection.select([.overview, .sandbox("a")], visibleIDs: visible)
        selection.select([.sandbox("a"), .sandbox("b")], visibleIDs: visible)
        try require(selection.items.count == 2 && selection.page == .sandbox("a"), "Cmd additive selection keeps focus")
        selection.navigate(to: .sandbox("a"))
        try require(selection.items.count == 2, "page echo must not collapse multi-selection")
        selection.select([.sandbox("a"), .sandbox("b"), .sandbox("c")], visibleIDs: visible)
        try require(selection.items.count == 3, "Shift range preserved")
        selection.select([.sandbox("b"), .sandbox("c")], visibleIDs: visible)
        try require(selection.items.count == 2 && selection.page == .sandbox("a"), "multi-selection keeps the previous page even when its row is deselected")
        selection.select([.sandbox("a"), .sandbox("b"), .sandbox("c"), .settings], visibleIDs: visible)
        try require(selection.items == Set(visible.map(Page.sandbox)) && selection.page == .sandbox("a"), "range selection excludes navigation rows")
        selection.select([.overview], visibleIDs: visible, extendingSelection: true)
        try require(selection.items == Set(visible.map(Page.sandbox)) && selection.page == .sandbox("a"), "modified navigation click preserves sandbox selection")
        selection.select([.settings], visibleIDs: visible)
        try require(selection.items == [.settings] && selection.page == .settings, "plain utility click navigates")
        selection.navigate(to: .sandbox("b"))
        try require(selection.items == [.sandbox("b")], "programmatic navigation selects one")
        selection.select([.sandbox("a"), .sandbox("b")], visibleIDs: visible)
        selection.prune(visibleIDs: ["a", "c"], existingIDs: ["a", "c"])
        try require(selection.items == [.sandbox("a")] && selection.page == .sandbox("a"), "deleted rows pruned")
        selection.prune(visibleIDs: [], existingIDs: [])
        try require(selection.items.isEmpty && selection.page == .overview, "empty list resets detail")
        selection.select([.sandbox("a")], visibleIDs: visible)
        selection.select([], visibleIDs: visible)
        try require(selection.items.isEmpty && selection.page == .sandbox("a"), "Cmd deselect last keeps the detail page")
        let tools: Set<Page> = [.overview, .activity, .settings]
        let allSandboxes = Set(visible.map(Page.sandbox))
        selection.navigate(to: .sandbox("b"))
        selection.select(allSandboxes.union(tools), visibleIDs: visible)
        try require(selection.items == allSandboxes && selection.page == .sandbox("b"), "native Select All excludes utility rows and keeps detail")
        selection.select(allSandboxes.union(tools), visibleIDs: visible)
        try require(selection.items == allSandboxes && selection.page == .sandbox("b"), "repeated Select All is idempotent")
        selection.navigate(to: .settings)
        selection.select(allSandboxes.union(tools), visibleIDs: visible)
        try require(selection.items == allSandboxes && selection.page == .settings, "Select All keeps previous tool page")
        selection.prune(visibleIDs: ["a", "c"], existingIDs: ["a", "c"])
        selection.select(tools.union([.sandbox("a"), .sandbox("c")]), visibleIDs: ["a", "c"])
        try require(selection.items == [.sandbox("a"), .sandbox("c")] && selection.page == .settings, "Select All only targets search results")
        selection.prune(visibleIDs: ["c"], existingIDs: visible)
        selection.select(tools.union([.sandbox("c")]), visibleIDs: ["c"])
        try require(selection.items == [.sandbox("c")] && selection.page == .sandbox("c"), "single-result Select All")
        selection.navigate(to: .settings)
        selection.select(tools, visibleIDs: [])
        try require(selection.items == [.settings] && selection.page == .settings, "empty Select All is a no-op")
        selection.navigate(to: .sandbox("b"))
        selection.select([], visibleIDs: ["a"])
        selection.prune(visibleIDs: ["a"], existingIDs: visible)
        try require(selection.items.isEmpty && selection.page == .sandbox("b"), "search hiding the selected instance preserves its page")
        selection.prune(visibleIDs: [], existingIDs: visible)
        try require(selection.page == .sandbox("b"), "no search results preserves the page")
        selection.prune(visibleIDs: visible, existingIDs: visible)
        try require(selection.items == [.sandbox("b")] && selection.page == .sandbox("b"), "clearing search restores sidebar highlight")
        selection.prune(visibleIDs: ["a"], existingIDs: ["a", "c"])
        try require(selection.page == .overview, "actual deletion still resets an unavailable page")
        selection.navigate(to: .sandbox("b"))
        selection.select([.sandbox("a"), .sandbox("b")], visibleIDs: visible)
        selection.prune(visibleIDs: ["a"], existingIDs: visible)
        selection.select([.sandbox("a")], visibleIDs: ["a"])
        try require(selection.page == .sandbox("b"), "List echo after filtering a multiselection cannot navigate")
        selection.select([.sandbox("c")], visibleIDs: ["a", "c"])
        try require(selection.page == .sandbox("c"), "explicitly choosing another search result navigates")
        selection.navigate(to: .activity)
        selection.select(allSandboxes.union(tools), visibleIDs: visible)
        selection.prune(visibleIDs: ["a"], existingIDs: visible)
        selection.select([.sandbox("a")], visibleIDs: ["a"])
        try require(selection.page == .activity, "filtering a multiselection also preserves a utility page")
        print("PASS sidebar multi-selection, navigation, search preservation, deletion and empty selection")

        func instance(_ id: String, _ state: String, actions: [String]) throws -> SandboxInstance {
            try JSONDecoder().decode(SandboxInstance.self, from: JSONSerialization.data(withJSONObject: ["id": id, "state": state, "createdAt": 0, "revisions": 1, "availableActions": actions]))
        }
        func status(pending: Int = 0, recovery: String? = nil, deletion: Bool = true, thermal: String = "nominal") throws -> ServiceStatus {
            var json: [String: Any] = ["permanentDeletionImplemented": deletion, "serviceVersion":"test", "protocolVersion":1,
                "activeInstances":0, "pendingExecutions":pending, "executionSlots":1, "appSandboxBackend":true,
                "host":["modelIdentifier":"test", "cpu":"test", "osVersion":"test", "memoryBytes":0, "thermalState":thermal]]
            if let recovery { json["recoveryReason"] = recovery }
            return try JSONDecoder().decode(ServiceStatus.self, from: JSONSerialization.data(withJSONObject: json))
        }
        try require(status(thermal: "critical").isThermallyPaused && status(thermal: "critical").recoveryReason == nil, "thermal pause is not quarantine")
        try require(!status(thermal: "serious").isThermallyPaused && !status().isThermallyPaused, "cooldown restores thermal admission")
        try require(status() == status(), "identical status snapshots compare equal")
        try require(status() != status(pending: 1) && status() != status(thermal: "critical") && status() != status(recovery: "fault"), "pending, thermal and isolation changes must still publish")
        let stopped = try [instance("a", "stopped", actions: ["delete"]), instance("b", "delete-failed", actions: ["delete"])]
        let deletion = SandboxBatch(action: .delete, ids: ["a", "b", "a"])
        try require(deletion.ids == ["a", "b"], "targets unique and ordered")
        try require(deletion.blockingReason(instances: stopped, status: status()) == nil, "eligible delete and explicit retry")
        try require(deletion.blockingReason(instances: [instance("a", "active", actions: ["stop"]), stopped[1]], status: status()) != nil, "mixed active delete blocked, not silently skipped")
        try require(deletion.blockingReason(instances: stopped + [instance("other", "active", actions: ["stop"])], status: status(pending: 2)) == nil, "unrelated running/queued work must not block deleting stopped targets; backend checks target commands")
        try require(instance("failed-live", "failed", actions: ["stop"]).canStop && !instance("failed-offline", "failed", actions: ["delete"]).canStop, "server actions, not state wording, determine eligibility")
        try require(deletion.blockingReason(instances: stopped, status: status(recovery: "quarantine")) == nil, "inactive file deletion does not require clearing execution quarantine")
        try require(deletion.blockingReason(instances: stopped, status: status(deletion: false)) != nil, "unsupported server")
        try require(deletion.blockingReason(instances: [stopped[0]], status: status()) != nil, "missing ID blocks whole batch")
        try require(deletion.blockingReason(instances: stopped, status: nil) != nil, "disconnected server")
        try require(SandboxBatch(action: .stop, ids: ["a"]).blockingReason(instances: stopped, status: status()) != nil, "already stopped not stoppable")
        print("PASS batch eligibility: target states, missing targets, server capability, unrelated busy queue and quarantine")

        let log = root.appendingPathComponent("calls.jsonl")
        func calls() throws -> [[String]] {
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        }
        try Data().write(to: log)
        let result = await deletion.execute { _, args in _ = try await client.sandbox(args).reply() }
        try require(result.completed == ["a", "b"] && result.issues.isEmpty, "batch success")
        try require(calls() == [client.configuration.sandbox(["delete", "a", "--confirm"]), client.configuration.sandbox(["delete", "b", "--confirm"])], "only exact frozen CLI delete targets, no canary or stop all")
        print("PASS sequential batch success through exact public CLI arguments")

        for action: SandboxBatchAction in [.stop, .delete] {
            for failure in ["fail", "rejected", "sleep", "malformed"] {
                try Data().write(to: log)
                let plan = SandboxBatch(action: action, ids: ["a", failure, "after_failure"])
                let partial = await plan.execute { _, args in _ = try await client.sandbox(args, timeout: 0.5).reply() }
                try require(partial.completed == ["a", "after_failure"] && partial.issues.map(\.id) == [failure], "continue after each error")
                try require(calls() == plan.ids.map { client.configuration.sandbox(action.arguments($0)) }, "every target attempted once in order, never retry")
                try require(partial.issues[0].reportedFailure == ["fail", "rejected"].contains(failure), "reported failure separated from unknown outcome")
                if failure == "sleep" { try require(partial.issues[0].error.contains(ui("结果未知", "result is unknown")), "timeout remains unknown") }
                try require(!partial.summary(action: action).contains("未执行："), "no unattempted suffix after an error")
            }
        }
        try Data().write(to: log)
        let regression = SandboxBatch(action: .delete, ids: ["a", "b", "invalid_ownership"] + (1...10).map { "later_\($0)" })
        let continued = await regression.execute { _, args in _ = try await client.sandbox(args).reply() }
        try require(continued.completed.count == 12 && continued.issues.map(\.id) == ["invalid_ownership"], "invalid ownership third target must not block remaining ten")
        try require(calls() == regression.ids.map { client.configuration.sandbox(regression.action.arguments($0)) }, "all thirteen explicit targets attempted exactly once")
        try require(continued.summary(action: .delete).contains(ui("失败：1 个", "Failed: 1")) && !continued.summary(action: .delete).contains(ui("结果未知：", "Unknown results:")), "ownership refusal labelled failure")
        try Data().write(to: log)
        let mixed = SandboxBatch(action: .delete, ids: ["fail", "a", "malformed", "b", "rejected", "fail"])
        let mixedResult = await mixed.execute { _, args in _ = try await client.sandbox(args).reply() }
        try require(mixedResult.completed == ["a", "b"] && mixedResult.issues.map(\.id) == ["fail", "malformed", "rejected"], "retain multiple errors including first and last")
        try require(calls() == mixed.ids.map { client.configuration.sandbox(mixed.action.arguments($0)) }, "multiple failures never retry or duplicate targets")
        let summary = mixedResult.summary(action: .delete)
        try require(summary.contains(ui("失败：2 个", "Failed: 2")) && summary.contains(ui("结果未知：1 个", "Unknown results: 1")), "summary separates reported failures and unknown outcomes")
        let allFailed = await SandboxBatch(action: .stop, ids: ["fail", "rejected"]).execute { _, args in _ = try await client.sandbox(args).reply() }
        try require(allFailed.completed.isEmpty && allFailed.issues.count == 2, "all failures are collected")
        let empty = await SandboxBatch(action: .delete, ids: []).execute { _, _ in throw CLIError("must not run") }
        try require(empty.completed.isEmpty && empty.issues.isEmpty, "empty batch sends no commands")
        print("PASS batch continues after every error: invalid ownership third-of-13, multiple/all failures, unknown outcomes; each target once, no retry/rollback")
    }

    static func live(bin: URL, state: String, output: URL) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CLIError("output must not exist") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let client = CLIClient(CLIConfiguration(directory: bin, stateDirectory: state))
        let status = try await client.sandbox(["status"]).reply().status
        try require(status?.appSandboxBackend == true && status?.executionSlots == 1, "native single-slot backend")
        let created = try await client.sandbox(["create", "--count", "2"]).reply().instances ?? []
        try require(created.count == 2 && created[0].id != created[1].id, "create two")
        var owned = created.map(\.id)
        var checks: [String] = []
        do {
            let id = created[0].id
            let listed = try await client.sandbox(["list"]).reply().instances ?? []
            try require(owned.allSatisfy { id in listed.contains { $0.id == id } }, "list created IDs")
            let detail = try await client.sandbox(["inspect", id]).reply().instance
            try require(detail?.isActive == true, "inspect")
            checks.append("create/list/inspect through packaged CLI")
            let input = output.appendingPathComponent("prompt.txt")
            let prompt = "题目\nquotes: ' \" ; $(not a command)\n"
            try prompt.write(to: input, atomically: true, encoding: .utf8)
            _ = try await client.sandbox(["write", id, "prompt.txt", "--from", input.path]).checked()
            let exec = try await client.submit(id: id, argv: ["/bin/cat", "prompt.txt"], cwd: ".", timeout: 30)
            let result = try await client.sandbox(["wait", exec]).checked()
            try require(result.text == prompt, "prompt byte roundtrip")
            let absent = try await client.sandbox(["read", created[1].id, "prompt.txt"])
            try require(absent.code != 0, "distinct workspaces")
            checks.append("write/exec/wait/read with isolated workspaces and exact prompt")
            let source = output.appendingPathComponent("fixture_main.c")
            try "#include <stdio.h>\nint main(void) { puts(\"packaged native success\"); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
            _ = try await client.sandbox(["write", id, "fixture_main.c", "--from", source.path]).checked()
            let compile = try await client.submit(id: id, argv: ["clang", "fixture_main.c", "-o", "fixture_program"], cwd: ".", timeout: 120)
            _ = try await client.sandbox(["wait", compile]).checked()
            let run = try await client.submit(id: id, argv: ["./fixture_program"], cwd: ".", timeout: 30)
            let native = try await client.sandbox(["wait", run]).checked()
            try require(native.text == "packaged native success\n", "compile and published execution")
            checks.append("sandboxed compile and signed native executable publication")
            let snapshot = output.appendingPathComponent("snapshot.zip")
            _ = try await client.sandbox(["export", id, "--out", snapshot.path]).checked()
            _ = try await client.sandbox(["import", created[1].id, "--from", snapshot.path]).checked()
            let imported = try await client.sandbox(["read", created[1].id, "prompt.txt"]).checked()
            try require(imported.text == prompt, "snapshot import")
            _ = try await client.sandbox(["stop", id]).checked()
            let restored = try await client.sandbox(["restore", id]).reply().instance
            guard let restored else { throw CLIError("restore returned no ID") }
            owned.append(restored.id)
            try require(restored.id != id, "restored fresh ID")
            let read = try await client.sandbox(["read", restored.id, "prompt.txt"]).checked()
            try require(read.text == prompt, "restore data")
            checks.append("snapshot export/import and checkpoint restore to new identity")
            for id in owned where id != created[0].id { _ = try await client.sandbox(["stop", id]).checked() }
            for id in owned { _ = try await client.sandbox(["delete", id, "--confirm"]).checked() }
            let record: [String: Any] = ["checks": checks, "result":"passed", "binaryDirectory":bin.path, "ownedInstances":owned]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("report.json"))
            checks.forEach { print("PASS \($0)") }
            print("4/4 packaged CLI integration groups passed")
        } catch {
            for id in owned { _ = try? await client.sandbox(["stop", id]) }
            throw error
        }
    }
}
