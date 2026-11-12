import Foundation
import Darwin
import SandboxCore
import SandboxRuntime

private let nativeHelp = """
sandboxctl [--state-dir PATH] sandbox [--handle FILE] COMMAND
  status                          Native manager capabilities and queue
  create --count N [--name NAME] [--no_network] [--task-policy FILE] [--env-file FILE] [--node ID] [--pool NAME] [--dynamic-scheduling]
  cluster                         Read cluster configuration
  forward ID --port N --lease UUID  Forward a local loopback service to the instance node
  forward-status ID UUID           Check and renew a forwarding lease (60 seconds)
  forward-close ID UUID            Close a forwarding lease
  list [-h|--human]                List instances as JSON, or a readable table
  env ID [--show-values | --from FILE]  List keys, explicitly reveal, or replace instance environment
  rename ID NAME                  Set display name; an empty name restores the ID label
  inspect ID                      Instance, physical bundle and checkpoint
  exec ID [--cwd REL] [--timeout S] [--env-file FILE|-] [--detach] [--session] -- PROGRAM [ARGS...]
  enter ID                        Managed command console; exit leaves sandbox running
  verify ID [--from TASK_FOLDER] [--timeout S] [--detach] [--after EXEC_ID]  Run tests, or register after an agent execution
  verification ID [--enabled true|false] [--timeout S]  Read/update automatic verification settings
  ls ID [--] [REL] [--after NAME]       List directory metadata (256 entries per page)
  trajectory ID [--session PATH] [--after CURSOR]  List/read supported harness conversation logs
  read ID REL [--out FILE]         Read through the restricted Host
  write ID REL --from FILE         Import bytes, never a host path into the manager
  export ID --out FILE             Save a streamed workspace archive (.zip)
  snapshot ID                     Save the managed workspace snapshot, without exporting a file
  import ID --from PATH [--task]   Import a snapshot; --task accepts a task folder only
  grant ID [--operations read,write,export,exec] --out FILE
  wait EXEC_ID | cancel EXEC_ID    Wait for/cancel an execution
  executions [--instance ID] [--limit N] [--before EXEC_ID]  Persistent execution history
  execution EXEC_ID               Read one command and its current result
  stop ID | stop --all             Save checkpoint and close instances
  delete ID --confirm             Permanently erase instance and workspace
  cleanup-deleted [--confirm]      Preview/remove drained shells covered by deletion audits
  cleanup-unclaimed [--bundle-id ID ... --confirm]  Preview/select unclaimed runtime artifacts
  reveal-containers BUNDLE_ID... [--preview]  Reveal exact container directories in Finder; never deletes
  reveal-file ID REL [--preview]   Reveal a validated workspace file or directory in Finder
  start ID                        Start original instance; keep ID, workspace and HOME
  restore ID                      Clone last valid stopped checkpoint into a new ID
  recover --confirm-processes-cleaned --note TEXT
  shutdown [--if-idle]             Stop the manager; --if-idle refuses active local instances/tasks

All commands execute inside App Sandbox. Allowlist: matches parallel, others serial.
Blocklist: matches serial, others parallel. Serial tasks share one slot.
The default allowlist includes sleep, common file/text utilities, git, curl,
archive tools, installed compilers, make, ninja and cmake --build. A match includes all descendants;
this is not GPU detection or exclusive GPU access. Shell scripts default to serial.
enter is a per-command console, NOT a persistent PTY: no vim, job control or
cross-command shell variables. Build/test/run scripts execute in place with the
selected compiler/SDK and installed CMake/Ninja; no shell command interception.
enter also accepts :run {"line":"pwd","timeout":30,"cwd":"."} for per-command settings.
Timed-out commands fail, but allow further execution after process-group cleanup.
Ctrl-C cancels the current command; cleaned cancellations also allow further execution.
Uncertain cleanup still requires inspection; cleanup does not certify GPU drain.
"""

private func printHumanInstances(_ instances: [NativeInstanceRecord]) {
    guard !instances.isEmpty else { print("No sandboxes."); return }
    let date = DateFormatter()
    date.locale = Locale(identifier: "en_US_POSIX")
    date.dateFormat = "yyyy-MM-dd HH:mm"
    let rows = [["ID", "NAME", "NODE", "STATE", "NETWORK", "POLICY", "CREATED (LOCAL)"]] + instances.map { instance in
        [instance.id, instance.name ?? "-", instance.nodeID ?? "local", instance.state.rawValue, instance.networkClient == true ? "on" : "off",
         instance.taskPolicy.map { $0.mode == .allowlist ? "allowlist" : "blocklist" } ?? "-",
         date.string(from: instance.createdAt)]
    }
    let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
    for row in rows {
        print(row.enumerated().map { column, value in
            column == row.count - 1 ? value : value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
        }.joined(separator: "  "))
    }
    print("\n\(instances.count) sandbox\(instances.count == 1 ? "" : "es").")
}

private struct ConsoleRequest: Decodable {
    let line: String
    let cwd: String?
    let timeout: Double

    func validate() throws {
        guard !line.isEmpty, line.utf8.count <= 8192, !line.contains("\0"), !line.contains("\n"), !line.contains("\r"),
              timeout.isFinite, timeout > 0 else { throw SandboxError("invalid console command or non-positive/non-finite timeout") }
        if let cwd, cwd != "." { _ = try ConfinedWorkspace.components(cwd) }
    }
}

// Parse only simple argv for the console. Metacharacters fall back to a shell
// INSIDE the Host, never a shell on the controller. This is not a shell parser.


func runNativeCLI(_ arguments: [String], state: URL) throws -> Int32 {
    var args = arguments
    if args.isEmpty || args == ["--help"] || args == ["help"] { print(nativeHelp); return 0 }
    var handle: SandboxHandle?
    if args.first == "--handle" {
        args.removeFirst()
        guard !args.isEmpty else { throw SandboxError("missing scoped handle file") }
        handle = try SafeFiles.read(SandboxHandle.self, from: URL(fileURLWithPath: args.removeFirst()))
    }
    guard !args.isEmpty else { throw SandboxError("missing native command") }
    let command = args.removeFirst()
    if command == "list", args == ["--help"] {
        print("Usage: sandboxctl [--state-dir PATH] sandbox list [-h|--human]\nDefault: JSON. -h / --human: readable table. --help: this help.")
        return 0
    }
    let token = try handle == nil ? NativeControlClient.operatorToken(stateDirectory: state) : nil
    func request(_ operation: String, _ configure: (inout NativeControlRequest) -> Void = { _ in }) throws -> NativeControlReply {
        var request = NativeControlRequest(operation)
        request.operatorToken = token; request.handle = handle; request.instanceID = handle?.instanceID
        configure(&request); return try NativeControlClient.request(request)
    }
    func transfer(_ operation: String, id: String, path: String? = nil, archive: URL, taskImport: Bool = false, tests: String? = nil) throws -> NativeControlReply {
        var request = NativeControlRequest(operation)
        request.operatorToken = token; request.handle = handle; request.instanceID = id; request.path = path
        request.taskImport = taskImport; request.testPackageSHA256 = tests
        return try NativeControlClient.transfer(request, archive: archive)
    }
    func cacheTests(_ source: URL, id: String) throws -> String {
        try WorkspaceArchive.temporary { archive in
            try TaskPackage.prepareTests(source, to: archive)
            guard let hash = try transfer("test-package", id: id, archive: archive).testPackageSHA256 else {
                throw SandboxError("missing stored test package SHA-256")
            }
            return hash
        }
    }
    func take(_ description: String) throws -> String {
        guard !args.isEmpty else { throw SandboxError("missing \(description)") }; return args.removeFirst()
    }
    func end() throws { guard args.isEmpty else { throw SandboxError("unexpected native arguments") } }
    func instanceID(_ value: String) throws -> String {
        if let handle {
            guard handle.instanceID.hasPrefix(value) else { throw SandboxError("ID does not match scoped handle") }; return handle.instanceID
        }
        let matching = try (request("list").instances ?? []).filter { $0.id.hasPrefix(value) }
        guard matching.count == 1 else { throw SandboxError("unknown or ambiguous sandbox ID prefix") }; return matching[0].id
    }
    func display(_ reply: NativeControlReply) throws { print(try JSON.string(reply)) }
    func wait(_ executionID: String) throws -> Int32 {
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
        interrupt.setEventHandler { _ = try? request("cancel") { $0.executionID = executionID } }
        interrupt.resume()
        defer { interrupt.cancel(); signal(SIGINT, SIG_DFL) }
        while true {
            guard let record = try request("execution", { $0.executionID = executionID }).execution else { throw SandboxError("missing execution") }
            if record.isTerminal {
                if let result = record.result {
                    FileHandle.standardOutput.write(result.stdout); FileHandle.standardError.write(result.stderr)
                }
                if let error = record.error { FileHandle.standardError.write(Data("\(record.id): \(error)\n".utf8)) }
                return record.error == nil ? (record.result?.outcome.exitCode ?? 1) : 1
            }
            usleep(100_000)
        }
    }
    func execute(_ id: String, _ argv: [String], cwd: String = ".", timeout: Double = 30, detach: Bool = false, session: Bool = false, reportExecution: Bool = false, verification: Bool = false, environment: [String: String]? = nil) throws -> Int32 {
        var cmd = NativeCommand(argv, cwd: cwd, timeoutSeconds: timeout)
        cmd.environment = environment
        cmd.agentSession = session ? true : nil
        cmd.verification = verification ? true : nil
        guard timeout.isFinite, timeout > 0 else { throw SandboxError("timeout must be a finite positive number") }
        let reply = try request("exec") { $0.instanceID = id; $0.command = cmd }
        guard let job = reply.execution else { throw SandboxError("missing execution ID") }
        if detach { try display(reply); return 0 }
        if reportExecution { print("[Execution ID: \(job.id)]"); fflush(stdout) }
        return try wait(job.id)
    }
    switch command {
    case "cluster": try end(); try display(request("cluster"))
    case "verification":
        let id = try instanceID(take("ID"))
        let current = try request("verification-settings") { $0.instanceID = id }
        guard var settings = current.verificationSettings else { throw SandboxError("missing verification settings") }
        if args.isEmpty { try display(current); return 0 }
        var options = Set<String>()
        while !args.isEmpty {
            let option = try take("option")
            guard options.insert(option).inserted else { throw SandboxError("duplicate verification option") }
            switch option {
            case "--enabled":
                let value = try take("true|false")
                guard ["true", "false"].contains(value) else { throw SandboxError("--enabled accepts true or false") }
                settings.enabled = value == "true"
            case "--timeout":
                guard let value = Double(try take("seconds")), value.isFinite, value > 0 else { throw SandboxError("invalid verification timeout") }
                settings.timeoutSeconds = value
            default: throw SandboxError("verification accepts --enabled true|false and --timeout S")
            }
        }
        try display(request("verification-settings") { $0.instanceID = id; $0.verificationSettings = settings })
    case "verify":
        let id = try instanceID(take("ID"))
        var source: URL?, timeout: Double?, detach = false, after: String?
        var options = Set<String>()
        while !args.isEmpty {
            let option = try take("option")
            guard options.insert(option).inserted else { throw SandboxError("duplicate verify option: " + option) }
            switch option {
            case "--from": source = URL(fileURLWithPath: try take("task folder"))
            case "--timeout":
                guard let value = Double(try take("seconds")), value.isFinite, value > 0 else {
                    throw SandboxError("verification timeout must be a finite positive number")
                }
                timeout = value
            case "--detach": detach = true
            case "--after": after = try take("agent execution ID")
            default: throw SandboxError("verify accepts --from TASK_FOLDER, --timeout S, --detach and --after EXEC_ID")
            }
        }
        guard try request("status").status?.taskVerificationImplemented == true else {
            throw SandboxError("restart the updated manager before using verify")
        }
        let hash = try source.map { try cacheTests($0, id: id) }
        let reply = try request("verify") {
            $0.instanceID = id; $0.executionID = after; $0.testPackageSHA256 = hash; $0.verificationTimeout = timeout
        }
        guard let execution = reply.execution else { throw SandboxError("missing verification execution") }
        if detach || after != nil { try display(reply); return 0 }
        return try wait(execution.id)
    case "forward", "forward-status", "forward-close":
        guard handle == nil else { throw SandboxError("loopback forwarding requires operator access") }
        let id = try take("full instance ID")
        guard id.hasPrefix("sbx-"), UUID(uuidString: String(id.dropFirst(4))) != nil else { throw SandboxError("forwarding requires a full instance ID") }
        let lease: String
        var port: Int?
        if command == "forward" {
            guard try take("--port") == "--port", let value = Int(try take("port")),
                  try take("--lease") == "--lease" else { throw SandboxError("forward ID --port N --lease UUID") }
            try LoopbackPort.validate(value); port = value; lease = try take("lease ID")
        } else { lease = try take("lease ID") }
        guard UUID(uuidString: lease) != nil else { throw SandboxError("forwarding lease must be a UUID") }
        try end()
        let operation = command == "forward" ? "port-forward-open" : "port-" + command
        try display(request(operation) { $0.instanceID = id; $0.forwardID = lease; $0.forwardPort = port })
    case "status": try end(); try display(request(command))
    case "shutdown":
        let onlyIfIdle = args == ["--if-idle"]
        if onlyIfIdle { args.removeAll() }
        try end()
        let processID = try request("status").serviceProcessID
        var monitor: Int32 = -1
        defer { if monitor >= 0 { close(monitor) } }
        if let processID {
            guard processID > 0 else { throw SandboxError("invalid service process identity") }
            monitor = kqueue()
            guard monitor >= 0 else { throw SandboxError("cannot observe service shutdown") }
            var event = kevent(ident: UInt(processID), filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
            guard kevent(monitor, &event, 1, nil, 0, nil) == 0 else {
                throw SandboxError("cannot observe service process: \(String(cString: strerror(errno)))")
            }
        }
        let reply = try request("shutdown") { $0.onlyIfIdle = onlyIfIdle }
        if monitor >= 0 {
            var event = kevent()
            while kevent(monitor, nil, 0, &event, 1, nil) < 0 {
                guard errno == EINTR else { throw SandboxError("service exit observation failed") }
            }
        }
        try display(reply)
    case "list":
        let human = args == ["-h"] || args == ["--human"]
        guard args.isEmpty || human else { throw SandboxError("list accepts only -h / --human, or --help") }
        let reply = try request("list")
        if human {
            guard let instances = reply.instances else { throw SandboxError("missing instance list") }
            printHumanInstances(instances)
        } else { try display(reply) }
    case "reveal-containers":
        guard handle == nil else { throw SandboxError("reveal-containers is a local operator action, not a scoped sandbox operation") }
        let preview = args.contains("--preview")
        let identifiers = args.filter { $0 != "--preview" }; args.removeAll()
        print(try JSON.string(revealContainers(identifiers, preview: preview)))
    case "reveal-file":
        guard handle == nil else { throw SandboxError("reveal-file requires the local operator") }
        let id = try instanceID(take("ID")), path = try take("workspace relative path")
        let preview = args == ["--preview"]
        if preview { args.removeFirst() }
        try end()
        guard let location = try request("workspace-location", { $0.instanceID = id; $0.path = path }).workspaceLocation else { throw SandboxError("missing workspace location") }
        print(try JSON.string(revealWorkspaceLocation(location, preview: preview)))
    case "create":
        guard try take("--count") == "--count", let count = Int(try take("count")) else { throw SandboxError("create --count N") }
        var network = true
        var networkSpecified = false
        var environment: [String: String]?
        var policy: TaskPolicy?
        var name: String?
        var nodeID: String?, schedulingPool: String?, dynamicScheduling = false
        while !args.isEmpty {
            let option = args.removeFirst()
            switch option {
            case "--node": nodeID = try take("node ID")
            case "--pool":
                guard schedulingPool == nil else { throw SandboxError("duplicate --pool") }
                schedulingPool = try take("pool name")
                try ClusterConfiguration.validatePool(schedulingPool)
            case "--dynamic-scheduling": dynamicScheduling = true
            case "--no_network":
                guard !networkSpecified else { throw SandboxError("duplicate or conflicting network options") }
                networkSpecified = true
                network = false
            case "--name":
                guard name == nil else { throw SandboxError("duplicate --name") }
                name = try take("name")
            case "--env-file":
                guard environment == nil else { throw SandboxError("duplicate --env-file") }
                environment = try EnvironmentVariables.decode(SafeFiles.readRegular(URL(fileURLWithPath: take("environment JSON file")), limit: FramedChannel.messageLimit))
            case "--task-policy":
                guard policy == nil else { throw SandboxError("duplicate --task-policy") }
                policy = try SafeFiles.read(TaskPolicy.self, from: URL(fileURLWithPath: take("policy JSON file")), limit: 128 * 1024)
                try policy?.validate()
            default: throw SandboxError("unknown create option")
            }
        }
        if network {
            guard try request("status").status?.networkClientImplemented == true else { throw SandboxError("service does not support per-instance network access") }
        }
        if policy != nil {
            guard try request("status").status?.perInstanceTaskPolicyImplemented == true else { throw SandboxError("service does not support per-instance task policies") }
        }
        if environment != nil {
            guard try request("status").status?.environmentImplemented == true else { throw SandboxError("service does not support instance environment") }
        }
        try display(request("create") { $0.count = count; $0.networkClient = network; $0.taskPolicy = policy; $0.environment = environment; $0.name = name; $0.nodeID = nodeID; $0.schedulingPool = schedulingPool; $0.dynamicScheduling = dynamicScheduling })
    case "rename":
        let id = try instanceID(take("ID")), name = try take("name")
        try end()
        try display(request("rename") { $0.instanceID = id; $0.name = name })
    case "env":
        let id = try instanceID(take("ID"))
        var values: [String: String]?, reveal = false
        if !args.isEmpty {
            switch try take("option") {
            case "--show-values": reveal = true
            case "--from": values = try EnvironmentVariables.decode(SafeFiles.readRegular(URL(fileURLWithPath: take("environment JSON file")), limit: FramedChannel.messageLimit))
            default: throw SandboxError("env accepts --show-values or --from FILE")
            }
        }
        try end()
        try display(request("environment") { $0.instanceID = id; $0.environment = values; $0.revealEnvironment = reveal })
    case "inspect", "start", "restore", "snapshot":
        let id = try instanceID(take("ID")); try end(); try display(request(command) { $0.instanceID = id })
    case "delete":
        let value = try take("ID")
        var confirmed = false
        while !args.isEmpty {
            switch try take("delete option") {
            case "--confirm": confirmed = true
            default: throw SandboxError("delete accepts --confirm")
            }
        }
        guard confirmed else { throw SandboxError("delete requires --confirm; data cannot be restored") }
        // A full ID is also accepted after deletion for an idempotent retry.
        let id = value.hasPrefix("sbx-") && UUID(uuidString: String(value.dropFirst(4))) != nil ? value : try instanceID(value)
        try display(request("delete") { $0.instanceID = id; $0.confirmed = true })
    case "cleanup-deleted", "cleanup-unclaimed":
        var confirmed = false, ids: [String] = []
        while !args.isEmpty {
            switch try take("cleanup option") {
            case "--confirm": confirmed = true
            case "--bundle-id": ids.append(try take("physical identity"))
            default: throw SandboxError("cleanup accepts --confirm and --bundle-id ID")
            }
        }
        let reply = try request(command) { $0.confirmed = confirmed; $0.bundleIDs = ids.isEmpty ? nil : ids }
        try display(reply)
        if reply.cleanup?.contains(where: { ["failed", "data-removed-shell-retained"].contains($0.state) }) == true {
            FileHandle.standardError.write(Data("Some cleanup operations failed; each was attempted once. See JSON cleanup for details. No automatic retries.\n".utf8)); return 1
        }
    case "stop":
        let value = try take("ID or --all"); try end()
        if value == "--all" {
            let records = try request("list").instances ?? []
            for record in records where record.availableActions?.contains(.stop) == true {
                do { try display(request("stop") { $0.instanceID = record.id }) }
                catch {
                    // Historical failed activations are not live registry entries.
                    if (error as? SandboxError)?.code != .instanceInactive { throw error }
                }
            }
        } else { let id = try instanceID(value); try display(request("stop") { $0.instanceID = id }) }
    case "exec":
        let id = try instanceID(take("ID")); var cwd = ".", timeout = 30.0, detach = false, session = false
        var environment: [String: String]?
        while args.first != "--" {
            switch try take("-- or exec option") {
            case "--cwd": cwd = try take("relative cwd")
            case "--timeout": guard let value = Double(try take("seconds")) else { throw SandboxError("invalid timeout") }; timeout = value
            case "--detach": detach = true
            case "--session": session = true
            case "--env-file":
                guard environment == nil else { throw SandboxError("duplicate --env-file") }
                let path = try take("environment JSON file or -")
                let data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile()
                    : try SafeFiles.readRegular(URL(fileURLWithPath: path), limit: FramedChannel.messageLimit)
                environment = try EnvironmentVariables.decode(data)
            default: throw SandboxError("unknown exec option; put -- before PROGRAM")
            }
        }
        args.removeFirst(); return try execute(id, args, cwd: cwd, timeout: timeout, detach: detach, session: session, environment: environment)
    case "executions":
        var id: String?, count = 100, before: String?
        while !args.isEmpty {
            switch try take("option") {
            case "--instance": id = try take("instance ID")
            case "--limit":
                guard let value = Int(try take("limit")) else { throw SandboxError("invalid history limit") }; count = value
            case "--before": before = try take("execution cursor")
            default: throw SandboxError("executions accepts --instance ID, --limit N and --before EXEC_ID")
            }
        }
        try display(request("executions") { $0.instanceID = id; $0.count = count; $0.after = before })
    case "execution":
        let id = try take("execution ID"); try end()
        try display(request("execution") { $0.executionID = id })
    case "wait", "cancel":
        let id = try take("execution ID"); try end()
        if command == "wait" { return try wait(id) }
        try display(request("cancel") { $0.executionID = id })
    case "trajectory":
        let id = try instanceID(take("ID"))
        var session: String?, after: String?
        while !args.isEmpty {
            switch try take("option") {
            case "--session": session = try take("session path")
            case "--after": after = try take("cursor")
            default: throw SandboxError("trajectory accepts --session PATH and --after CURSOR")
            }
        }
        try display(request("trajectory") { $0.instanceID = id; $0.path = session; $0.after = after })
    case "ls":
        let id = try instanceID(take("ID"))
        let path: String
        if args.first == "--" { args.removeFirst(); path = try take("relative directory") }
        else { path = args.first != nil && args.first != "--after" ? try take("relative directory") : "." }
        var after: String?
        if !args.isEmpty {
            guard try take("--after") == "--after" else { throw SandboxError("ls accepts [REL] [--after NAME]") }
            after = try take("cursor name")
        }
        try end(); try display(request("ls") { $0.instanceID = id; $0.path = path; $0.after = after })
    case "read", "write":
        let id = try instanceID(take("ID")), relative = try take("relative file")
        if command == "write" {
            guard try take("--from") == "--from" else { throw SandboxError("write needs --from FILE") }
            let source = URL(fileURLWithPath: try take("FILE")); try end()
            try WorkspaceArchive.temporary { archive in
                try WorkspaceArchive.fromFile(source, path: relative, to: archive)
                try display(transfer("upload", id: id, archive: archive))
            }
        } else {
            var destination: URL?
            if !args.isEmpty {
                guard try take("--out") == "--out" else { throw SandboxError("read accepts --out FILE") }
                destination = URL(fileURLWithPath: try take("FILE"))
            }
            try end()
            try WorkspaceArchive.temporary { archive in
                _ = try transfer("download", id: id, path: relative, archive: archive)
                try WorkspaceArchive.extractFile(archive, path: relative, to: destination)
            }
        }
    case "export", "import":
        let id = try instanceID(take("ID"))
        guard try take("file option") == (command == "export" ? "--out" : "--from") else { throw SandboxError("invalid snapshot file option") }
        let url = URL(fileURLWithPath: try take("FILE"))
        let task = command == "import" && args.first == "--task"
        if task { args.removeFirst() }
        try end()
        if command == "export" {
            // Validate before replacing a user's previous export.
            try WorkspaceArchive.temporary { archive in
                _ = try transfer("download", id: id, archive: archive)
                try WorkspaceArchive.copy(archive, to: url)
            }
        } else if task {
            try WorkspaceArchive.temporary { archive in
                try TaskPackage.prepare(url, to: archive)
                let tests = url.appendingPathComponent("tests")
                var info = stat()
                let found = lstat(tests.path, &info) == 0
                guard found || errno == ENOENT else { throw SandboxError("cannot inspect task tests directory") }
                guard !found || info.st_mode & S_IFMT == S_IFDIR else { throw SandboxError("tests must be a real directory") }
                let nonempty = try found && !FileManager.default.contentsOfDirectory(atPath: tests.path).isEmpty
                let hash = try nonempty ? cacheTests(url, id: id) : nil
                _ = try transfer("upload", id: id, archive: archive, taskImport: true, tests: hash)
            }
        } else if try WorkspaceArchive.isArchive(url) {
            try WorkspaceArchive.read(url)
            _ = try transfer("upload", id: id, archive: url)
        } else {
            throw SandboxError("snapshot import requires a ZIP archive; workspace unchanged")
        }
    case "grant":
        let id = try instanceID(take("ID")); var operations: Set<SandboxOperation> = [.read, .write, .export, .exec]
        if args.first == "--operations" {
            args.removeFirst(); let names = try take("operations").split(separator: ",").map(String.init)
            let values = names.compactMap(SandboxOperation.init(rawValue:))
            guard names.count == values.count else { throw SandboxError("invalid scoped operation") }; operations = Set(values)
        }
        guard try take("--out") == "--out" else { throw SandboxError("grant requires --out FILE") }
        let file = URL(fileURLWithPath: try take("FILE")); try end()
        guard let granted = try request("grant", { $0.instanceID = id; $0.operations = operations }).handle else { throw SandboxError("missing scoped capability") }
        try SafeFiles.write(granted, to: file)
    case "recover":
        guard try take("confirmation") == "--confirm-processes-cleaned", try take("--note") == "--note" else { throw SandboxError("recovery requires explicit confirmation and --note") }
        let note = try take("note"); try end(); try display(request("recover") { $0.confirmed = true; $0.note = note })
    case "enter":
        let id = try instanceID(take("ID")); try end(); var cwd = "."
        _ = try request("inspect") { $0.instanceID = id }
        let interactive = isatty(STDIN_FILENO) == 1
        if interactive { print("Managed command console. Each command is queued. :help / :exit; not a persistent PTY.") }
        while true {
            if interactive { print("\(id.prefix(12)):\(cwd)> ", terminator: ""); fflush(stdout) }
            guard var line = readLine() else { break }
            do {
                var commandCwd = cwd, timeout = 30.0
                let configured = line.hasPrefix(":run ")
                if configured {
                    guard line.utf8.count <= 65536 else { throw SandboxError("console request too large") }
                    let value = try JSONDecoder().decode(ConsoleRequest.self, from: Data(line.dropFirst(5).utf8))
                    try value.validate()
                    line = value.line; commandCwd = value.cwd ?? cwd; timeout = value.timeout
                }
                let argv = shellCommandArguments(line)
                if argv.isEmpty { continue }
                if [":exit", "exit"].contains(argv[0]) { break }
                if argv[0] == ":help" { print("Simple commands use argv; shell operators use /bin/sh inside the sandbox. cd REL changes this console's cwd. exit leaves the sandbox running. :run JSON accepts line, timeout (positive seconds), and optional workspace-relative cwd for one command."); fflush(stdout); continue }
                if ["cd", ":cd"].contains(argv[0]) {
                    guard argv.count == 2, !argv[1].hasPrefix("/") else { throw SandboxError("cd needs a workspace-relative directory") }
                    var parts = commandCwd == "." ? [] : commandCwd.split(separator: "/").map(String.init)
                    for part in argv[1].split(separator: "/").map(String.init) {
                        if part == "." { continue }
                        if part == ".." { guard !parts.isEmpty else { throw SandboxError("cannot leave workspace") }; parts.removeLast() }
                        else { parts.append(part) }
                    }
                    let next = parts.isEmpty ? "." : parts.joined(separator: "/")
                    let code = try execute(id, ["/bin/pwd"], cwd: next, timeout: timeout, reportExecution: configured)
                    if code == 0 { cwd = next }
                    if configured { print("\n[Exit code: \(code)]"); fflush(stdout) }
                } else {
                    let code = try execute(id, argv, cwd: commandCwd, timeout: timeout, reportExecution: configured)
                    if configured { print("\n[Exit code: \(code)]"); fflush(stdout) }
                }
            } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
        }
    default: throw SandboxError("unknown native command\n\(nativeHelp)")
    }
    return 0
}
