import Foundation
import Darwin
import SandboxCore
import SandboxRuntime

private final class ExecutionState {
    let lock = NSLock()
    var active: [String: CancellationToken] = [:]
    var agentLeases = Set<String>()
    var completed: [String: HostResponse] = [:]
    var quarantined = false
    var usedLeases = Set<String>()
    func cancel(_ lease: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let lease { active[lease]?.cancel() }
        else { active.values.forEach { $0.cancel() } }
    }
}

func serve() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.isEmpty || arguments == ["--files-only"] else { throw SandboxError("unsupported Host mode") }
    let filesOnly = !arguments.isEmpty
    let home = FileManager.default.homeDirectoryForCurrentUser
    guard let bundleID = Bundle.main.bundleIdentifier, bundleID.hasPrefix("local.metal-sandbox."),
          home.path.hasSuffix("/Library/Containers/\(bundleID)/Data") else {
        throw SandboxError("App Sandbox container not activated; refusing unsandboxed fallback")
    }
    let base = home.appendingPathComponent("Library/Application Support/MetalSandbox")
    let sharedURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/shared_workspace.json")
    let shared = try FileManager.default.fileExists(atPath: sharedURL.path) ? SafeFiles.read(SharedWorkspace.self, from: sharedURL) : nil
    let workspaceURL = shared?.workspace ?? base.appendingPathComponent("workspace")
    if let shared {
        for path in [shared.workspace, shared.home] {
            var st = stat()
            guard lstat(path.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { throw SandboxError("shared directory is not available; refusing an empty replacement") }
        }
    }
    try SafeFiles.secureDirectory(workspaceURL)
    let workspace = try ConfinedWorkspace(directory: workspaceURL)
    let temporary = base.appendingPathComponent("tmp")
    let developmentHome = shared?.home ?? base.appendingPathComponent("home")
    try SafeFiles.secureDirectory(temporary)
    try SafeFiles.secureDirectory(developmentHome)
    let trajectory = try AgentTrajectory(home: developmentHome)
    let scopes = try DevelopmentScopes(directories: [workspaceURL, temporary, developmentHome])
    defer { withExtendedLifetime(scopes) {} }
    let toolchain = try SafeFiles.read(InstalledClang.self, from: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/development_toolchain.json"))
    let environment = toolchain.environment.merging([
        "METAL_SANDBOX_CONTAINER_HOME": home.path,
        "METAL_SANDBOX_WORKSPACE": workspaceURL.path,
        "METAL_SANDBOX_BRIDGE_DIRECTORY": temporary.path,
        "METAL_SANDBOX_SHELL_HELPER": Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sandbox-shell").path,
        "PATH": toolchain.searchDirectories.joined(separator: ":") + ":" + developmentHome.appendingPathComponent(".local/bin").path,
    ]) { _, new in new }.merging(AgentHarnesses.environment(resources: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"))) { _, new in new }
    let taskPolicy = try SafeFiles.read(TaskPolicy.self, from: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/task_policy.json"))
    let channel = try FramedChannel(input: STDIN_FILENO, output: STDOUT_FILENO)
    var info = HostInfoReply(bundleID: bundleID, home: home.path,
        temporary: FileManager.default.temporaryDirectory.path, workspace: workspaceURL.path,
        bundle: Bundle.main.bundleURL.path, pid: getpid(), uid: getuid())
    info.fileOnly = filesOnly
    let state = ExecutionState()
    let worker = DispatchQueue(label: "sandbox-host.execution", attributes: .concurrent)
    let work = DispatchGroup()
    guard chdir(temporary.path) == 0 else { throw SandboxError("cannot enter private runtime directory") }
    let bridge = try HostShellBridge { parent in
        state.lock.lock(); defer { state.lock.unlock() }
        return state.active[parent].map { !$0.isCancelled } ?? false
    }
    defer { bridge.close() }
    let downloads = DispatchQueue(label: "sandbox-host.download")
    // EOF/manager death cancels the live child and waits for its actual parent
    // to reap it. The manager's durable lease remains for operator inspection.
    defer { state.cancel(); bridge.cancel(); work.wait(); downloads.sync {} }
    while let request = try channel.receive(HostRequest.self, timeout: .infinity) {
        if filesOnly && ![.info, .read, .write, .listDirectory, .validateDirectory, .trajectory, .workspaceLocation, .export, .download, .upload, .purge, .cancel, .shutdown].contains(request.operation) {
            var reply = HostResponse(id: request.id); reply.ok = false; reply.error = "file-only Host cannot execute commands"
            try channel.send(reply); continue
        }
        if request.operation == .cancel {
            state.cancel(request.leaseID); bridge.cancel(parent: request.leaseID)
            continue // one-way; cancellation cannot steal an exec reply
        }
        // A download owns the response stream through its final chunk, while
        // the main loop remains available for one-way execution cancellation.
        downloads.sync {}
        if request.operation == .shutdown {
            state.cancel(); bridge.cancel(); work.wait()
            try channel.send(HostResponse(id: request.id)); return
        }
        if request.operation == .download || request.operation == .upload {
            // The ready response precedes raw chunk frames. Once it is sent,
            // transport errors terminate this pipe rather than desynchronize it.
            var ready = HostResponse(id: request.id)
            state.lock.lock(); let busy = !state.active.isEmpty; state.lock.unlock()
            let liveRead = request.operation == .download && request.path != nil
            if busy && !liveRead { ready.ok = false; ready.error = "Host execution in progress"; try channel.send(ready); continue }
            if request.operation == .download {
                downloads.async {
                    do {
                        try WorkspaceArchive.temporary(directory: temporary) { archive in
                            var reply = HostResponse(id: request.id)
                            do { try workspace.exportArchive(to: archive, path: request.path) }
                            catch { reply.ok = false; reply.error = String(describing: error) }
                            try channel.send(reply)
                            if reply.ok { _ = try channel.sendFile(archive) }
                        }
                    } catch {
                        // A broken transfer cannot be reused as framed IPC.
                        // Reap the actual child before closing this Host.
                        state.cancel(); bridge.cancel(); work.wait()
                        FileHandle.standardError.write(Data("download failed: \(error)\n".utf8))
                        exit(1)
                    }
                }
            } else {
                try WorkspaceArchive.temporary(directory: temporary) { archive in
                    try channel.send(ready)
                    let failure = try channel.receiveFile(to: archive)
                    do {
                        if let failure { throw failure }
                        if request.path == "tests" { try workspace.replaceTests(from: archive) }
                        else {
                            guard request.path == nil else { throw SandboxError("invalid upload destination") }
                            try workspace.importArchive(from: archive)
                        }
                    } catch { ready.ok = false; ready.error = String(describing: error) }
                    try channel.send(ready)
                }
            }
            continue
        }
        var response = HostResponse(id: request.id)
        do {
            state.lock.lock(); let busy = !state.active.isEmpty; state.lock.unlock()
            guard !busy || request.operation.allowedDuringExecution else {
                throw SandboxError("Host execution in progress")
            }
            switch request.operation {
            case .workspaceLocation:
                let path = request.path ?? "."; try workspace.validateFileOrDirectory(path)
                response.workspaceLocation = path == "." ? workspaceURL.path : workspaceURL.appendingPathComponent(path).path
            case .trajectory:
                response.trajectory = try trajectory.read(session: request.path, after: request.after)
            case .info: response.info = info
            case .shellRequests:
                response.shellInvocations = bridge.pending(); response.cancelledShellIDs = bridge.cancelledIDs()
            case .shellReject:
                guard let id = request.shellID else { throw SandboxError("missing shell rejection ID") }
                try bridge.reject(id)
            case .shellGrant:
                guard let id = request.shellID, let lease = request.leaseID else { throw SandboxError("missing shell grant") }
                try bridge.grant(id, lease: lease)
            case .shellResult:
                guard let id = request.shellID else { throw SandboxError("missing shell result ID") }
                response.result = try bridge.result(id)
            case .shellRemoteResult:
                guard let id = request.shellID, let result = request.result else { throw SandboxError("missing remote shell result") }
                try bridge.completeRemote(id, result: result)
            case .shellRemoteStarted:
                guard let id = request.shellID else { throw SandboxError("missing remote shell start") }
                try bridge.startRemote(id)
            case .listDirectory:
                response.directory = try workspace.listDirectory(request.path ?? ".", after: request.after)
            case .validateDirectory:
                try workspace.validateDirectory(request.path ?? ".")
            case .validateExecutable:
                guard let path = request.path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                    throw SandboxError("command not found or not executable in sandbox")
                }
            case .classifyCommand:
                guard let command = request.command else { throw SandboxError("missing command") }
                try command.validate(); try workspace.validateDirectory(command.cwd)
                let configured = request.environment ?? [:]
                try EnvironmentVariables.validate(configured)
                response.allowsParallel = taskPolicy.allowsParallel(command,
                    shellEnvironment: environment.merging(configured) { _, value in value },
                    workingDirectory: workspaceURL.appendingPathComponent(command.cwd).standardizedFileURL.path)
            case .read:
                guard let path = request.path else { throw SandboxError("missing path") }
                response.file = try workspace.read(path)
            case .write:
                guard let file = request.file else { throw SandboxError("missing file") }
                try workspace.write(file)
            case .export: response.files = try workspace.export()
            case .executionResult:
                if let lease = request.leaseID { response.schedulerWaitSeconds = bridge.waitingSeconds(parent: lease) }
                state.lock.lock(); defer { state.lock.unlock() }
                if let lease = request.leaseID, let completed = state.completed.removeValue(forKey: lease) {
                    response = completed; response.id = request.id
                } else if request.leaseID == nil || state.active[request.leaseID!] == nil {
                    throw SandboxError("unknown execution lease")
                }
            case .purge:
                // Fixed private maintenance RPC, never an Agent command. The
                // Host can only erase its own App Sandbox Data container.
                state.lock.lock(); let mayPurge = !state.quarantined && state.usedLeases.isEmpty; state.lock.unlock()
                guard mayPurge else { throw SandboxError("purge requires a fresh maintenance Host") }
                if request.purgeSharedWorkspace == true {
                    guard shared != nil else { throw SandboxError("missing shared workspace for purge") }
                    try workspace.removeAll()
                    try ConfinedWorkspace(directory: developmentHome).removeAll()
                }
                // These OS-created aliases are protected by App Sandbox, not
                // task data. Verify exact link targets; never follow them.
                try ConfinedWorkspace(directory: home).removeAll(preservingLinks: [
                    "Library/Preferences/com.apple.security.plist": "../../../../../Preferences/com.apple.security.plist",
                    "Library/Preferences/com.apple.security_common.plist": "../../../../../Preferences/com.apple.security_common.plist",
                ])
            case .recover:
                let runningCalls = bridge.hasRunningCalls
                state.lock.lock(); defer { state.lock.unlock() }
                guard Set(state.active.keys).isSubset(of: state.agentLeases), !runningCalls else {
                    throw SandboxError("Host recovery requires no running task commands")
                }
                state.quarantined = false
            case .exec:
                let configuredEnvironment = request.environment ?? [:]
                try EnvironmentVariables.validate(configuredEnvironment)
                guard let lease = request.leaseID, UUID(uuidString: lease) != nil,
                      let command = request.command else { throw SandboxError("missing execution lease or command") }
                try command.validate(); try workspace.validateDirectory(command.cwd)
                let token = CancellationToken()
                state.lock.lock()
                let allowed = !state.quarantined && state.usedLeases.count < 10000 && state.usedLeases.insert(lease).inserted
                if allowed {
                    state.active[lease] = token
                    if command.agentSession == true { state.agentLeases.insert(lease) }
                }
                state.lock.unlock()
                guard allowed else { throw SandboxError("reused lease or quarantined Host") }
                let queueWait = bridge.begin(parent: lease)
                work.enter()
                worker.async {
                    defer { work.leave() }
                    var reply = HostResponse(id: request.id)
                    var quarantine = true
                    do {
                        let logs = base.appendingPathComponent("executions/\(lease)")
                        try SafeFiles.secureDirectory(logs)
                        let output = logs.appendingPathComponent("stdout.log"), error = logs.appendingPathComponent("stderr.log")
                        let outcome = try ProcessRunner.run(argv: command.argv,
                            workingDirectory: command.cwd == "." ? workspaceURL : workspaceURL.appendingPathComponent(command.cwd),
                            home: developmentHome, temporary: temporary,
                            stdout: output, stderr: error, timeout: command.timeoutSeconds,
                            maxLogBytes: command.maxLogBytes, jobID: lease, cancellation: token,
                            environmentOverrides: environment.merging(configuredEnvironment) { _, value in value }
                                .merging(["METAL_SANDBOX_AGENT_SESSION": command.agentSession == true ? "1" : "0"]) { _, value in value },
                            excludedSeconds: { command.deadlineUptimeNanoseconds == nil ? queueWait.seconds : 0 })
                        quarantine = outcome.requiresInspection
                        func log(_ url: URL) -> Data {
                            (try? SafeFiles.readRegular(url, limit: command.maxLogBytes + 65536)) ?? Data("[log unavailable or too large]".utf8)
                        }
                        reply.result = NativeResult(leaseID: lease, outcome: outcome,
                            stdout: outcome.reason == .launchFailed ? Data() : log(output),
                            stderr: outcome.reason == .launchFailed ? Data() : log(error))
                    } catch { reply.ok = false; reply.error = String(describing: error) }
                    bridge.finish(parent: lease); reply.schedulerWaitSeconds = queueWait.seconds
                    state.lock.lock()
                    state.quarantined = state.quarantined || quarantine; state.completed[lease] = reply; state.active.removeValue(forKey: lease)
                    state.agentLeases.remove(lease)
                    state.lock.unlock()
                }
                // Reply now; the controller retrieves completion by lease.
            case .download, .upload, .cancel, .shutdown: break
            }
        } catch { response.ok = false; response.error = String(describing: error) }
        try channel.send(response)
    }
}

do { try serve() }
catch { FileHandle.standardError.write(Data("sandbox-host: \(error)\n".utf8)); exit(1) }
