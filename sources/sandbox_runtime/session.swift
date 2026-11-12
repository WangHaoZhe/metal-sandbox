import Foundation
import CryptoKit
import Security
import Darwin
import SandboxCore

/// Role-free interface. The evaluation layer maps instances to Agent/Verifier.
/// Implementations must serialize file mutation/export with candidate execution.
public protocol SandboxSession: AnyObject {
    var id: String { get }
    func workspaceLocation(_ path: String) throws -> String
    func trajectory(session: String?, after: String?) throws -> TrajectoryReply
    func read(_ path: String) throws -> WorkspaceFile
    func listDirectory(_ path: String, after: String?) throws -> WorkspaceDirectory
    func write(_ file: WorkspaceFile) throws
    func export() throws -> [WorkspaceFile]
    func download(to url: URL, path: String?) throws
    func upload(from url: URL) throws
    func execute(_ command: NativeCommand) throws -> NativeResult
    func execute(_ command: NativeCommand, cancellation: CancellationToken) throws -> NativeResult
    func execute(_ command: NativeCommand, cancellation: CancellationToken, onGranted: () throws -> Void) throws -> NativeResult
    func close() throws
}

public extension SandboxSession {
    func workspaceLocation(_ path: String) throws -> String { throw SandboxError("workspace reveal not supported") }
    func trajectory(session: String?, after: String?) throws -> TrajectoryReply {
        throw SandboxError("trajectory reading is not supported by this session")
    }
    func download(to url: URL, path: String? = nil) throws {
        let files = try path.map { [try read($0)] } ?? export()
        try WorkspaceArchive.write(url) { writer in for file in files { try writer.append(file) } }
    }
    func upload(from url: URL) throws {
        for file in try WorkspaceArchive.collect(url) { try write(file) }
    }
    func listDirectory(_ path: String, after: String?) throws -> WorkspaceDirectory {
        throw SandboxError("directory listing is not supported by this session")
    }
    func execute(_ command: NativeCommand, cancellation: CancellationToken, onGranted: () throws -> Void) throws -> NativeResult {
        try onGranted(); return try execute(command, cancellation: cancellation)
    }
    func execute(_ command: NativeCommand, cancellation: CancellationToken) throws -> NativeResult {
        guard !cancellation.isCancelled else { throw SandboxError("cancelled before execution") }
        return try execute(command)
    }
}

public enum AppSignature {
    public static func verify(_ url: URL, inherited: Bool, approvedToolchain: InstalledClang? = nil, networkClient: Bool = false, sharedWorkspace: SharedWorkspace? = nil) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw SandboxError("invalid signed runtime: \(url.path)")
        }
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let info = dictionary as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            throw SandboxError("cannot inspect runtime entitlements")
        }
        let expected: [String: Any]
        if inherited { expected = ["com.apple.security.app-sandbox": true, "com.apple.security.inherit": true] }
        else {
            guard let identifier = Bundle(url: url)?.bundleIdentifier, let approvedToolchain else { throw SandboxError("missing approved runtime identity/toolchain") }
            expected = DevelopmentPolicy.hostEntitlements(identifier: identifier, toolchain: approvedToolchain, networkClient: networkClient, sharedWorkspace: sharedWorkspace)
        }
        guard NSDictionary(dictionary: entitlements).isEqual(to: expected) else {
            throw SandboxError("runtime entitlements differ from approved scoped development policy")
        }
    }
}

/// Experimental backend, also used by the trusted acceptance harness. This type
/// never uses an unsandboxed candidate launcher. Public Agent integration stays
/// gated separately until behavioral acceptance has passed on the target Mac.
public final class AppSandboxSession: SandboxSession {
    public var clusterTasks: ClusterTaskQueue?
    public var clusterTask: ((NativeCommand, [String: String]) throws -> ClusterTask?)?
    public let id: String
    public let publishedCandidate: PublishedCandidate?
    public private(set) var info: HostInfoReply!
    private let process = Process()
    private let fileOnly: Bool
    private let input = Pipe(), output = Pipe()
    private let channel: FramedChannel
    private let scheduler: ExecutionScheduler
    private let taskPolicy: TaskPolicy?
    private let mutex = NSRecursiveLock()
    private let execution = NSRecursiveLock()
    private var closed = false
    private let errorLog: FileHandle
    private let recordURL: URL
    private let shellQueue = DispatchQueue(label: "sandbox-session.shell-poll")
    private var shellPoller: DispatchSourceTimer?
    private let shellLock = NSLock()
    private var shellTokens: [String: CancellationToken] = [:]
    private let shellWork = DispatchGroup()
    private let activityLock = NSLock()
    private var activeExecutions = 0
    private var failedHostHadWork: Bool?

    public convenience init(app: URL, stateDirectory: URL, scheduler: ExecutionScheduler, toolchain: InstalledClang) throws {
        try self.init(app: app, stateDirectory: stateDirectory, scheduler: scheduler, toolchain: toolchain, publishedCandidate: nil)
    }
    init(app: URL, stateDirectory: URL, scheduler: ExecutionScheduler, toolchain: InstalledClang, publishedCandidate: PublishedCandidate?, networkClient: Bool = false, taskPolicy: TaskPolicy? = nil, fileOnly: Bool = false) throws {
        self.fileOnly = fileOnly
        self.scheduler = scheduler
        try taskPolicy?.validate(); self.taskPolicy = taskPolicy
        self.publishedCandidate = publishedCandidate
        guard let bundle = Bundle(url: app), let identifier = bundle.bundleIdentifier,
              identifier.hasPrefix("local.metal-sandbox."),
              identifier.dropFirst("local.metal-sandbox.".count).allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }),
              !identifier.hasSuffix(".") else { throw SandboxError("unapproved sandbox bundle identity") }
        id = identifier
        let sharedURL = app.appendingPathComponent("Contents/Resources/shared_workspace.json")
        let shared = try FileManager.default.fileExists(atPath: sharedURL.path) ? SafeFiles.read(SharedWorkspace.self, from: sharedURL) : nil
        try AppSignature.verify(app, inherited: false, approvedToolchain: toolchain, networkClient: networkClient, sharedWorkspace: shared)
        for name in ["sandbox-probe", "metal-runner", "sandbox-shell"] {
            try AppSignature.verify(app.appendingPathComponent("Contents/MacOS/\(name)"), inherited: true)
        }
        if let publishedCandidate {
            let executable = app.appendingPathComponent("Contents/MacOS/candidate")
            try AppSignature.verify(executable, inherited: true)
            guard PublishedCandidate.digest(try SafeFiles.readRegular(executable, limit: .max)) == publishedCandidate.signedSHA256 else {
                throw SandboxError("published candidate signature/hash mismatch")
            }
        }
        let directory = stateDirectory.appendingPathComponent(identifier)
        try SafeFiles.secureDirectory(directory)
        recordURL = directory.appendingPathComponent("instance.json")
        let stderr = directory.appendingPathComponent("host-stderr.log")
        try SafeFiles.writeData(Data(), to: stderr)
        errorLog = try FileHandle(forWritingTo: stderr)
        channel = try FramedChannel(input: output.fileHandleForReading.fileDescriptor, output: input.fileHandleForWriting.fileDescriptor)
        process.executableURL = app.appendingPathComponent("Contents/MacOS/sandbox-host")
        process.arguments = fileOnly ? ["--files-only"] : []
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errorLog
        let exitURL = directory.appendingPathComponent("host_exit.json")
        process.terminationHandler = { child in
            try? SafeFiles.write(["pid": String(child.processIdentifier),
                                  "reason": child.terminationReason == .exit ? "exit" : "signal",
                                  "status": String(child.terminationStatus),
                                  "recordedAt": ISO8601DateFormatter().string(from: Date())], to: exitURL)
        }
        try SafeFiles.write(["id": id, "state": "starting", "app": app.path], to: recordURL)
        do {
            try process.run()
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            let reply = try request(HostRequest(.info))
            if let info = reply.info { try SafeFiles.write(info, to: directory.appendingPathComponent("handshake.json")) }
            guard let info = reply.info, info.bundleID == identifier,
                  info.protocolVersion == 3, (info.fileOnly ?? false) == fileOnly, info.uid == getuid(), info.pid == process.processIdentifier,
                  // URL equality also compares the directory/trailing-slash
                  // hint, which can change after the bundle has been created.
                  URL(fileURLWithPath: info.bundle).standardizedFileURL.path == app.standardizedFileURL.path,
                  info.home.hasSuffix("/Library/Containers/\(identifier)/Data") else {
                throw SandboxError("Host identity/container handshake failed")
            }
            self.info = info
            if !fileOnly {
                let poller = DispatchSource.makeTimerSource(queue: shellQueue)
                poller.schedule(deadline: .now(), repeating: .milliseconds(30))
                poller.setEventHandler { [weak self] in self?.pollShells() }
                shellPoller = poller; poller.resume()
            }
            try SafeFiles.write(["id": id, "state": "active", "pid": String(info.pid),
                                 "home": info.home, "workspace": info.workspace], to: recordURL)
        } catch {
            if process.isRunning { process.terminate() }
            try? SafeFiles.write(["id": id, "state": "activation-failed", "error": String(describing: error)], to: recordURL)
            throw error
        }
    }
    private func pollShells() {
        do {
            let reply = try request(HostRequest(.shellRequests))
            let calls = reply.shellInvocations ?? []
            for call in calls {
                let token = CancellationToken()
                shellLock.lock(); shellTokens[call.id] = token; shellLock.unlock()
                shellWork.enter()
                DispatchQueue.global().async { [self] in
                    defer { shellLock.lock(); shellTokens.removeValue(forKey: call.id); shellLock.unlock(); shellWork.leave() }
                    do {
                        let offer: ClusterDelegation?
                        if !call.parallel, let queue = clusterTasks, let make = clusterTask,
                           let script = call.script, let cwd = call.cwd, let environment = call.environment {
                            let command = NativeCommand([call.shell ?? "/bin/bash", "-c", script], cwd: cwd,
                                timeoutSeconds: call.command.timeoutSeconds, maxLogBytes: call.command.maxLogBytes)
                            offer = try make(command, environment).map { queue.add($0, cancellation: token) }
                        } else { offer = nil }
                        defer { if let offer { clusterTasks?.remove(offer.task.id) } }
                        let result = try scheduler.run(command: call.command, taskPolicy: taskPolicy, parallel: call.parallel, cancellation: token, ownerID: self.id, parentID: call.parent, delegation: offer, onRemoteStarted: {
                            var notification = HostRequest(.shellRemoteStarted); notification.shellID = call.id
                            _ = try request(notification)
                        }) { lease in
                            var grant = HostRequest(.shellGrant); grant.shellID = call.id; grant.leaseID = lease
                            _ = try request(grant)
                            while true {
                                var query = HostRequest(.shellResult); query.shellID = call.id
                                if let result = try request(query).result { return result }
                                Thread.sleep(forTimeInterval: 0.03)
                            }
                        }
                        if offer?.isClaimed == true {
                            var delivered = HostRequest(.shellRemoteResult); delivered.shellID = call.id; delivered.result = result
                            _ = try request(delivered)
                            while true {
                                var query = HostRequest(.shellResult); query.shellID = call.id
                                if try request(query).result != nil { break }
                                Thread.sleep(forTimeInterval: 0.03)
                            }
                        }
                    } catch {
                        // run() retains evidence for uncertain post-grant failures.
                        // Queued cancellations have not launched any shell.
                        var reject = HostRequest(.shellReject); reject.shellID = call.id
                        _ = try? request(reject)
                    }
                }
            }
            shellLock.lock()
            for id in reply.cancelledShellIDs ?? [] { shellTokens[id]?.cancel() }
            shellLock.unlock()
        } catch {
            if let failure = hostFailure {
                shellPoller?.cancel()
                if clusterTasks != nil {
                    shellLock.lock(); shellTokens.values.forEach { $0.cancel() }; shellLock.unlock()
                }
                if failure.hadWork { try? scheduler.requireInspection(failure.message) }
            }
        }
    }
    private var hostFailure: (message: String, hadWork: Bool)? {
        guard process.processIdentifier > 0, !process.isRunning else { return nil }
        activityLock.lock(); defer { activityLock.unlock() }
        if failedHostHadWork == nil {
            shellLock.lock(); defer { shellLock.unlock() }
            failedHostHadWork = activeExecutions > 0 || !shellTokens.isEmpty
        }
        let reason = process.terminationReason == .exit ? "exit code" : "signal"
        let recovery = failedHostHadWork == true ? "Stop this disconnected instance, inspect and recover the node, then restart the instance. " : "This instance is unavailable; stop it and restart it. "
        return ("Sandbox Host exited (PID \(process.processIdentifier), \(reason) \(process.terminationStatus)); the control connection was lost. \(recovery)The workspace is retained.", failedHostHadWork == true)
    }
    public var connectionError: String? { hostFailure?.message }
    public func acknowledgeRecovery() throws {
        _ = try request(HostRequest(.recover))
        activityLock.lock(); failedHostHadWork = nil; activityLock.unlock()
    }
    private func request(_ request: HostRequest, timeout: Double = 10, onSent: () -> Void = {}) throws -> HostResponse {
        mutex.lock(); defer { mutex.unlock() }
        guard !closed else { throw SandboxError("sandbox session closed") }
        if let failure = connectionError { throw SandboxError(failure) }
        let reply: HostResponse
        do {
            try channel.send(request)
            onSent()
            guard let received = try channel.receive(HostResponse.self, timeout: timeout), received.id == request.id else {
                throw SandboxError("Host exited or private IPC response ID mismatch")
            }
            reply = received
        } catch {
            throw SandboxError(connectionError ?? "Sandbox Host control connection failed: \(error). Commands are not replayed automatically; check the instance state.")
        }
        guard reply.ok else { throw SandboxError(reply.error ?? "Host rejected request") }
        return reply
    }
    public func read(_ path: String) throws -> WorkspaceFile {
        try WorkspaceArchive.temporary { url in
            try download(to: url, path: path)
            guard let file = try WorkspaceArchive.collect(url).first else { throw SandboxError("missing file") }
            return file
        }
    }
    private func disconnectTransfer() {
        closed = true
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
    }
    public func download(to url: URL, path: String?) throws {
        _ = try downloadArchive(to: url, path: path)
    }
    /// Validate the staged ZIP once, before replacement, and reuse its metadata.
    public func downloadArchive(to url: URL, path: String?) throws -> (summary: WorkspaceArchive.Summary, sha256: String) {
        if path == nil { execution.lock() }
        defer { if path == nil { execution.unlock() } }
        mutex.lock(); defer { mutex.unlock() }
        var r = HostRequest(.download); r.path = path
        _ = try request(r, timeout: .infinity)
        let failure: Error?
        var summary: WorkspaceArchive.Summary?, hash = SHA256()
        do {
            failure = try channel.receiveFile(to: url,
                validate: { summary = try WorkspaceArchive.read($0) },
                didWrite: { hash.update(data: $0) })
        }
        catch { disconnectTransfer(); throw error }
        if let failure { throw failure }
        guard let summary else { throw SandboxError("archive validation did not complete") }
        return (summary, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    public func upload(from url: URL) throws {
        try upload(from: url, replacingTests: false)
    }
    public func upload(from url: URL, replacingTests: Bool) throws {
        execution.lock(); defer { execution.unlock() }
        mutex.lock(); defer { mutex.unlock() }
        try WorkspaceArchive.read(url)
        var r = HostRequest(.upload)
        if replacingTests { r.path = "tests" }
        _ = try request(r)
        let failure: Error?, reply: HostResponse?
        do {
            failure = try channel.sendFile(url)
            reply = try channel.receive(HostResponse.self, timeout: .infinity)
        } catch { disconnectTransfer(); throw error }
        guard let reply, reply.id == r.id else { disconnectTransfer(); throw SandboxError("Host upload reply mismatch") }
        if let failure { throw failure }
        guard reply.ok else { throw SandboxError(reply.error ?? "Host upload failed") }
    }
    public func trajectory(session: String?, after: String?) throws -> TrajectoryReply {
        mutex.lock(); defer { mutex.unlock() }
        var r = HostRequest(.trajectory); r.path = session; r.after = after
        guard let reply = try request(r).trajectory else { throw SandboxError("missing trajectory reply") }
        return reply
    }
    public func workspaceLocation(_ path: String) throws -> String {
        var r = HostRequest(.workspaceLocation); r.path = path
        guard let location = try request(r).workspaceLocation else { throw SandboxError("missing workspace location") }
        return location
    }
    public func listDirectory(_ path: String, after: String?) throws -> WorkspaceDirectory {
        mutex.lock(); defer { mutex.unlock() }
        var r = HostRequest(.listDirectory); r.path = path; r.after = after
        guard let directory = try request(r).directory, directory.path == path else { throw SandboxError("invalid directory reply") }
        return directory
    }
    public func write(_ file: WorkspaceFile) throws {
        try WorkspaceArchive.temporary { url in
            try WorkspaceArchive.write(url) { try $0.append(file) }; try upload(from: url)
        }
    }
    public func export() throws -> [WorkspaceFile] {
        try WorkspaceArchive.temporary { url in
            try download(to: url, path: nil); return try WorkspaceArchive.collect(url)
        }
    }
    public func purgeContainer(sharedWorkspace: Bool = false) throws {
        execution.lock(); defer { execution.unlock() }
        mutex.lock(); defer { mutex.unlock() }
        var request = HostRequest(.purge); request.purgeSharedWorkspace = sharedWorkspace
        _ = try self.request(request, timeout: 120)
    }
    public func allowsParallel(_ command: NativeCommand, environment: [String: String]) throws -> Bool {
        try command.validate()
        if command.verification == true { return false }
        if command.agentSession == true { return true }
        let taskPolicy = taskPolicy ?? scheduler.taskPolicy
        if taskPolicy.mode == .blocklist || !TaskPolicy.isShell(command.argv.first ?? "") {
            return taskPolicy.allowsParallel(command)
        }
        var query = HostRequest(.classifyCommand); query.command = command
        query.environment = environment.merging(command.environment ?? [:]) { _, value in value }
        guard let result = try request(query).allowsParallel else { throw SandboxError("missing task classification") }
        return result
    }
    public func execute(_ command: NativeCommand) throws -> NativeResult {
        try execute(command, cancellation: CancellationToken())
    }
    public func execute(_ command: NativeCommand, cancellation: CancellationToken) throws -> NativeResult {
        try execute(command, cancellation: cancellation, onGranted: {})
    }
    public func execute(_ command: NativeCommand, cancellation: CancellationToken, onGranted: () throws -> Void) throws -> NativeResult {
        try execute(command, cancellation: cancellation, environment: [:], onGranted: onGranted)
    }
    public func execute(_ command: NativeCommand, cancellation: CancellationToken, environment: [String: String], reservationID: String? = nil, onGranted: () throws -> Void) throws -> NativeResult {
        guard !fileOnly else { throw SandboxError("file-only Host cannot execute commands") }
        if let failure = connectionError { throw SandboxError(failure) }
        activityLock.lock(); activeExecutions += 1; activityLock.unlock()
        defer { activityLock.lock(); activeExecutions -= 1; activityLock.unlock() }
        try EnvironmentVariables.validate(environment)
        try command.validate()
        let executionEnvironment = environment.merging(command.environment ?? [:]) { _, value in value }
        // A missing cwd is an input error, not uncertain GPU completion. Check
        // it inside the Host before granting a launch lease. The exec handler
        // still checks again; failures after grant remain fail-closed.
        if command.cwd != "." {
            var validation = HostRequest(.validateDirectory); validation.path = command.cwd
            _ = try request(validation)
        }
        var resolved = command
        if let candidate = publishedCandidate, try candidate.matches(command) {
            // Do not silently execute an older published binary after the caller
            // edits its workspace copy. A new revision needs a fresh publication.
            guard try read(candidate.source.path) == candidate.source else {
                throw SandboxError("workspace executable differs from its frozen publication")
            }
            resolved.argv[0] = info.bundle + "/Contents/MacOS/candidate"
        }
        var executableCheck = HostRequest(.validateExecutable)
        let executable = resolved.argv[0]
        executableCheck.path = executable.hasPrefix("/") ? executable
            : URL(fileURLWithPath: info.workspace).appendingPathComponent(command.cwd).appendingPathComponent(executable).standardizedFileURL.path
        _ = try request(executableCheck)
        let parallel = reservationID == nil ? try allowsParallel(resolved, environment: environment) : false
        let offer: ClusterDelegation?
        if !parallel, reservationID == nil, command.deadlineUptimeNanoseconds == nil, let queue = clusterTasks, let make = clusterTask {
            offer = try make(resolved, executionEnvironment).map { queue.add($0, cancellation: cancellation) }
        } else { offer = nil }
        defer { if let offer { clusterTasks?.remove(offer.task.id) } }
        return try scheduler.run(command: resolved, taskPolicy: taskPolicy, parallel: parallel, cancellation: cancellation, deadlineUptimeNanoseconds: command.deadlineUptimeNanoseconds, ownerID: id, delegation: offer, reservationID: reservationID, onRemoteStarted: onGranted) { lease in
            var executionConfirmed = false
            defer {
                if !executionConfirmed {
                    // Process termination callbacks can arrive after an IPC
                    // failure. Do not later mistake lost execution for idle exit.
                    activityLock.lock(); failedHostHadWork = true; activityLock.unlock()
                }
            }
            try onGranted()
            // One-way cancellation on the private pipe; never signal a stale PID
            // or expose this pipe/lease to the candidate. Host remains responsive
            // while its execution worker reaps the actual child.
            let cancellationQueue = DispatchQueue(label: "sandbox-session.cancellation")
            let timer = DispatchSource.makeTimerSource(queue: cancellationQueue)
            timer.schedule(deadline: .now() + .milliseconds(30), repeating: .milliseconds(30))
            let channel = self.channel
            timer.setEventHandler {
                if cancellation.isCancelled {
                    var cancel = HostRequest(.cancel); cancel.leaseID = lease
                    try? channel.send(cancel, timeout: 1)
                }
            }
            var resumed = false
            defer {
                if !resumed { timer.resume() }; timer.cancel()
                // No late cancel frame may land inside a subsequent upload.
                cancellationQueue.sync {}
            }
            // Launch is acknowledged immediately. Only each IPC transaction,
            // not the entire process lifetime, holds the pipe mutex. Thus reads
            // can proceed without stealing an exec reply or mixing ZIP chunks.
            let deadline: UInt64 = try {
                mutex.lock(); defer { mutex.unlock() }
                // A file transaction may have delayed admission to the pipe.
                // Recompute the remaining budget before actually spawning.
                var bounded = resolved
                if let deadline = command.deadlineUptimeNanoseconds {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard deadline > now else { throw SandboxError("deadline expired before spawn") }
                    bounded.timeoutSeconds = min(bounded.timeoutSeconds, Double(deadline - now) / 1e9)
                }
                var r = HostRequest(.exec); r.command = bounded; r.leaseID = lease; r.environment = executionEnvironment
                let end = MonotonicDeadline.after(bounded.timeoutSeconds + ExecutionTiming.resultGraceSeconds)
                _ = try request(r, onSent: { resumed = true; timer.resume() })
                return end
            }()
            while true {
                var query = HostRequest(.executionResult); query.leaseID = lease
                let reply = try request(query)
                let childWait = reply.schedulerWaitSeconds ?? 0
                cancellation.queueWait.setChildWait(childWait)
                if let result = reply.result {
                    executionConfirmed = !result.outcome.requiresInspection
                    return result
                }
                let now = DispatchTime.now().uptimeNanoseconds
                let extensionNanoseconds = command.deadlineUptimeNanoseconds == nil
                    ? UInt64(min(childWait * 1e9, Double(UInt64.max / 2))) : 0
                let extended = deadline.addingReportingOverflow(extensionNanoseconds)
                guard now < (extended.overflow ? UInt64.max : extended.partialValue) else {
                    throw SandboxError("Host execution result deadline exceeded")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
    public func close() throws {
        shellPoller?.cancel(); shellQueue.sync {}; shellPoller = nil
        shellLock.lock(); shellTokens.values.forEach { $0.cancel() }; shellLock.unlock()
        mutex.lock(); if !closed { try? channel.send(HostRequest(.cancel)) }; mutex.unlock()
        shellWork.wait()
        execution.lock(); defer { execution.unlock() }
        mutex.lock(); defer { mutex.unlock() }
        if closed { return }
        defer {
            closed = true
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errorLog.close()
        }
        if let failure = hostFailure, !failure.hadWork {
            // A dead idle Host had no candidate execution to drain. Retire its
            // control handles, retaining host_exit.json as the failure record.
            try SafeFiles.write(["id": id, "state": "stopped"], to: recordURL)
            return
        }
        _ = try request(HostRequest(.shutdown))
        let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < end { usleep(10_000) }
        guard !process.isRunning else { process.terminate(); throw SandboxError("Host shutdown timed out") }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SandboxError("Host shutdown was not a clean exit")
        }
        try SafeFiles.write(["id": id, "state": "stopped"], to: recordURL)
    }
    deinit {
        // Normal callers close explicitly. Closing stdin makes an idle Host exit;
        // never delete OS-managed container structures from the controller.
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
