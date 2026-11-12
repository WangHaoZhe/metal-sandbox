import Foundation
import Darwin
import SandboxCore

public struct ShellInvocation: Codable {
    public var script: String?
    public var shell: String?
    public var cwd: String?
    public var environment: [String: String]?
    public var id: String
    public var parent: String
    public var command: NativeCommand
    public var parallel: Bool
}
private struct ShellBridgeReply: Codable {
    var result: NativeResult?
    var remote: Bool?
    var ok = true
    var cancelled = false
    var error: String?
    var outcome: ProcessOutcome?
    var processGroupID: Int32?
}

private func shellSocketAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let path = Array("./shell_bridge.sock".utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    return try withUnsafePointer(to: &address) {
        try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

/// The listener lives INSIDE this Host's private TMPDIR. No management socket,
/// operator token, shared directory entitlement or network permission is exposed.
public final class HostShellBridge {
    private final class Call {
        let invocation: ShellInvocation
        var cancelled = false
        var announced = false
        var lease: String?
        var done = false
        var outcome: ProcessOutcome?
        var error: String?
        var remoteResult: NativeResult?
        var remoteRunning = false
        var processGroupID: Int32?
        var startedAt: UInt64?
        init(_ invocation: ShellInvocation) { self.invocation = invocation }
    }
    private let condition = NSCondition()
    private var calls: [String: Call] = [:]
    private var parentClocks: [String: QueueWaitClock] = [:]
    public func begin(parent: String) -> QueueWaitClock {
        condition.lock(); defer { condition.unlock() }
        let clock = QueueWaitClock(); parentClocks[parent] = clock
        return clock
    }
    public func finish(parent: String) {
        condition.lock(); defer { condition.unlock() }
        parentClocks.removeValue(forKey: parent)?.setWaiting(false)
    }
    public func waitingSeconds(parent: String) -> Double {
        condition.lock(); defer { condition.unlock() }
        return parentClocks[parent]?.seconds ?? 0
    }
    // Exclude the union of blocked intervals, never the sum of child waits.
    // A running sibling keeps the session's execution budget advancing.
    private func updateClock(_ parent: String) {
        let active = calls.values.filter { $0.invocation.parent == parent && !$0.done && !$0.cancelled }
        parentClocks[parent]?.setWaiting(!active.isEmpty && active.allSatisfy { $0.lease == nil && !$0.remoteRunning })
    }
    private let listener: Int32
    private var closed = false
    private let work = DispatchGroup()
    private let parentActive: (String) -> Bool
    public init(parentActive: @escaping (String) -> Bool) throws {
        self.parentActive = parentActive
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SandboxError("cannot create shell bridge socket") }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        _ = unlink("./shell_bridge.sock")
        do {
            try shellSocketAddress { guard bind(listener, $0, $1) == 0 else { throw SandboxError("cannot bind private shell bridge") } }
            guard chmod("./shell_bridge.sock", 0o600) == 0, listen(listener, 64) == 0 else { throw SandboxError("cannot listen on private shell bridge") }
        } catch { Darwin.close(listener); throw error }
        work.enter()
        DispatchQueue.global().async { [self] in
            defer { work.leave() }
            while true {
                condition.lock(); let stop = closed; condition.unlock()
                if stop { return }
                var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                if poll(&poller, 1, 100) <= 0 { continue }
                let fd = accept(listener, nil, nil)
                if fd < 0 { continue }
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                work.enter()
                DispatchQueue.global().async { [self] in defer { work.leave(); Darwin.close(fd) }; serve(fd) }
            }
        }
    }
    private func serve(_ fd: Int32) {
        var call: Call?
        do {
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw SandboxError("foreign shell bridge peer") }
            let channel = try FramedChannel(input: fd, output: fd)
            guard let input = try channel.receive(ShellInvocation.self, timeout: 10), UUID(uuidString: input.id) != nil,
                  parentActive(input.parent) else { throw SandboxError("shell bridge requires an active parent session") }
            try input.command.validate()
            let item = Call(input); call = item
            condition.lock()
            guard !closed, calls[input.id] == nil, calls.count < 64 else { condition.unlock(); throw SandboxError("shell bridge unavailable") }
            calls[input.id] = item
            updateClock(input.parent)
            while item.lease == nil && !item.remoteRunning && !item.cancelled && !closed {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                var byte: UInt8 = 0
                if !parentActive(input.parent) || recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0 {
                    item.cancelled = true
                    updateClock(input.parent)
                }
            }
            let run = !item.cancelled && !closed
            let remote = item.remoteRunning
            condition.unlock()
            if !run && !remote {
                condition.lock()
                item.outcome = ProcessOutcome(processID: 0, reason: .cancelled, elapsedSeconds: 0, cleanupSeconds: 0)
                item.done = true; updateClock(input.parent); condition.broadcast(); condition.unlock()
                try channel.send(ShellBridgeReply(ok: false, cancelled: true)); return
            }
            try channel.send(ShellBridgeReply(remote: remote ? true : nil))
            if remote {
                condition.lock()
                while item.remoteResult == nil && !closed && !item.cancelled {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                    var byte: UInt8 = 0
                    if !parentActive(input.parent) || recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0 { item.cancelled = true }
                }
                guard let result = item.remoteResult else {
                    item.cancelled = true; item.done = true
                    updateClock(input.parent); condition.broadcast()
                    condition.unlock()
                    try channel.send(ShellBridgeReply(ok: false, cancelled: true, error: "remote task could not complete"))
                    return
                }
                condition.unlock()
                try channel.send(ShellBridgeReply(result: result))
            }
            var cancellationSent: Date?
            while true {
                condition.lock(); let cancel = item.cancelled || closed; condition.unlock()
                if !remote, (cancel || !parentActive(input.parent)) && cancellationSent == nil {
                    try channel.send(ShellBridgeReply(cancelled: true))
                    cancellationSent = Date()
                }
                if let sent = cancellationSent, Date().timeIntervalSince(sent) > 5 {
                    throw SandboxError("shell cancellation completion was not acknowledged")
                }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&poller, 1, 30) <= 0 { continue }
                guard let result = try channel.receive(ShellBridgeReply.self, timeout: 10), result.ok else {
                    throw SandboxError("shell wrapper disconnected without a completion record")
                }
                if let group = result.processGroupID {
                    guard !remote, group > 0, item.processGroupID == nil, result.outcome == nil else {
                        throw SandboxError("invalid shell process group registration")
                    }
                    condition.lock(); item.processGroupID = group; item.startedAt = DispatchTime.now().uptimeNanoseconds; condition.unlock()
                    try channel.send(ShellBridgeReply(cancelled: cancel || !parentActive(input.parent), processGroupID: group))
                    continue
                }
                guard let outcome = result.outcome else { throw SandboxError("missing shell completion record") }
                condition.lock(); item.outcome = outcome; item.done = true; updateClock(input.parent); condition.broadcast(); condition.unlock()
                try channel.send(ShellBridgeReply()); break
            }
        } catch {
            if let call {
                condition.lock()
                let group = call.done ? nil : call.processGroupID
                let startedAt = call.startedAt
                condition.unlock()
                var cancelled: ProcessOutcome?
                if let group {
                    let cleanupStart = DispatchTime.now().uptimeNanoseconds
                    let cleanup = ProcessGroup.clean(group)
                    let now = DispatchTime.now().uptimeNanoseconds
                    var outcome = ProcessOutcome(processID: group, reason: .cancelled,
                        elapsedSeconds: Double(now - (startedAt ?? cleanupStart)) / 1e9,
                        cleanupSeconds: Double(now - cleanupStart) / 1e9, processGroupGone: cleanup.gone)
                    outcome.cleanupDiagnostics = cleanup.diagnostics
                    cancelled = outcome
                }
                condition.lock()
                if !call.done {
                    if let cancelled { call.outcome = cancelled; call.cancelled = true }
                    else { call.error = String(describing: error) }
                    call.done = true
                }
                updateClock(call.invocation.parent)
                condition.broadcast(); condition.unlock()
            }
        }
    }
    public func pending() -> [ShellInvocation] {
        condition.lock(); defer { condition.unlock() }
        return calls.values.filter { !$0.announced }.map { $0.announced = true; return $0.invocation }
    }
    public var hasRunningCalls: Bool {
        condition.lock(); defer { condition.unlock() }
        return calls.values.contains { !$0.done && ($0.lease != nil || $0.remoteRunning) }
    }
    public func grant(_ id: String, lease: String) throws {
        condition.lock(); defer { condition.unlock() }
        guard let call = calls[id], call.lease == nil else { throw SandboxError("unknown or already granted shell invocation") }
        call.lease = lease; updateClock(call.invocation.parent); condition.broadcast()
    }
    public func completeRemote(_ id: String, result: NativeResult) throws {
        condition.lock(); defer { condition.unlock() }
        guard let call = calls[id], call.lease == nil else { throw SandboxError("remote shell already granted") }
        call.remoteResult = result; call.lease = result.leaseID
        if call.done { call.outcome = result.outcome; call.error = nil }
        updateClock(call.invocation.parent); condition.broadcast()
    }
    public func startRemote(_ id: String) throws {
        condition.lock(); defer { condition.unlock() }
        guard let call = calls[id], call.lease == nil else { throw SandboxError("remote shell already granted") }
        call.remoteRunning = true; updateClock(call.invocation.parent)
    }
    public func result(_ id: String) throws -> NativeResult? {
        condition.lock(); defer { condition.unlock() }
        guard let call = calls[id] else { throw SandboxError("unknown shell invocation") }
        guard call.done else { return nil }
        calls.removeValue(forKey: id)
        updateClock(call.invocation.parent)
        if let error = call.error { throw SandboxError(error) }
        guard let outcome = call.outcome, let lease = call.lease else { throw SandboxError("incomplete shell invocation") }
        return NativeResult(leaseID: lease, outcome: outcome, stdout: Data(), stderr: Data())
    }
    public func cancelledIDs() -> [String] {
        condition.lock(); defer { condition.unlock() }
        return calls.values.filter { $0.cancelled && $0.lease == nil }.map { $0.invocation.id }
    }
    public func reject(_ id: String) throws {
        condition.lock(); defer { condition.unlock() }
        guard let call = calls[id] else { return }
        guard call.lease == nil else { throw SandboxError("cannot reject a granted shell") }
        call.cancelled = true; calls.removeValue(forKey: id); updateClock(call.invocation.parent); condition.broadcast()
    }
    public func cancel(parent: String? = nil) {
        condition.lock(); defer { condition.unlock() }
        for call in calls.values where parent == nil || call.invocation.parent == parent {
            call.cancelled = true
        }
        for parent in parentClocks.keys { updateClock(parent) }
        condition.broadcast()
    }
    public func close() {
        condition.lock(); closed = true; condition.broadcast(); condition.unlock()
        cancel(); _ = shutdown(listener, SHUT_RDWR); work.wait(); Darwin.close(listener)
        _ = unlink("./shell_bridge.sock")
    }
}

public enum ShellBridgeClient {
    public static func run(script: String, command: NativeCommand, directory: URL, shell: String, parallel: Bool, startNotification: Int32? = nil) throws -> Int32 {
        let environment = try AgentHarnesses.selected(environment: ProcessInfo.processInfo.environment)
            .toolEnvironment(ProcessInfo.processInfo.environment)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SandboxError("cannot create shell bridge client") }
        defer { Darwin.close(fd) }; _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let cwd = open(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard cwd >= 0 else { throw SandboxError("cannot retain shell working directory") }
        defer { Darwin.close(cwd) }
        guard chdir(directory.path) == 0 else { throw SandboxError("cannot enter private shell bridge directory") }
        do { try shellSocketAddress { guard connect(fd, $0, $1) == 0 else { throw SandboxError("shell bridge unavailable; command not executed") } } }
        catch { _ = fchdir(cwd); throw error }
        guard fchdir(cwd) == 0 else { throw SandboxError("cannot restore shell working directory") }
        let channel = try FramedChannel(input: fd, output: fd)
        guard let parent = ProcessInfo.processInfo.environment["METAL_SANDBOX_JOB_ID"] else { throw SandboxError("missing managed parent session") }
        let queuedAt = DispatchTime.now().uptimeNanoseconds
        if !parallel {
            FileHandle.standardError.write(Data("[Metal Sandbox] Waiting for the shared serial slot; the command has not started.\n".utf8))
        }
        var invocation = ShellInvocation(id: UUID().uuidString.lowercased(), parent: parent, command: command, parallel: parallel)
        if let workspace = ProcessInfo.processInfo.environment["METAL_SANDBOX_WORKSPACE"] {
            let current = FileManager.default.currentDirectoryPath
            if current == workspace || current.hasPrefix(workspace + "/") {
                invocation.script = script; invocation.shell = shell
                invocation.cwd = current == workspace ? "." : String(current.dropFirst(workspace.count + 1))
                invocation.environment = environment.filter { key, _ in
                    !["HOME", "TMPDIR", "WORKSPACE"].contains(key) && !key.hasPrefix("METAL_SANDBOX_")
                }
            }
        }
        try channel.send(invocation)
        guard let ready = try channel.receive(ShellBridgeReply.self, timeout: .infinity), ready.ok else { throw SandboxError("shell command was not granted") }
        if ready.remote == true {
            if let startNotification {
                let notification = FileHandle(fileDescriptor: startNotification, closeOnDealloc: false)
                try notification.write(contentsOf: Data([1])); try notification.close()
            }
            guard let message = try channel.receive(ShellBridgeReply.self, timeout: .infinity), message.ok, let result = message.result else { throw SandboxError("remote shell did not complete") }
            FileHandle.standardOutput.write(result.stdout); FileHandle.standardError.write(result.stderr)
            try channel.send(ShellBridgeReply(outcome: result.outcome))
            _ = try channel.receive(ShellBridgeReply.self, timeout: 10)
            return result.outcome.reason == .exited ? result.outcome.exitCode ?? 1 : 128 + (result.outcome.terminationSignal ?? SIGTERM)
        }
        let waited = Double(DispatchTime.now().uptimeNanoseconds - queuedAt) / 1e9
        if !parallel {
            FileHandle.standardError.write(Data(String(format: "[Metal Sandbox] Serial slot acquired after %.3f s; starting command.\n", waited).utf8))
        }
        let token = CancellationToken()
        let queue = DispatchQueue(label: "shell-bridge.cancellation")
        let monitor = DispatchSource.makeTimerSource(queue: queue)
        monitor.schedule(deadline: .now(), repeating: .milliseconds(20))
        monitor.setEventHandler {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&poller, 1, 0) > 0 {
                // Only this monitor reads while the child is running. A clean
                // cancellation keeps the channel open for its cleanup receipt.
                do {
                    let message = try channel.receive(ShellBridgeReply.self, timeout: 1)
                    if message == nil || message?.cancelled == true { token.cancel() }
                } catch { token.cancel() }
            }
        }
        var signals: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { token.cancel() }; source.resume(); signals.append(source)
        }
        var monitoring = false
        defer {
            if !monitoring { monitor.resume() }
            monitor.cancel(); signals.forEach { $0.cancel() }; queue.sync {}
        }
        let home = URL(fileURLWithPath: environment["HOME"]!)
        let outcome = try ProcessRunner.run(argv: [shell, "-c", script], workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            home: home, temporary: directory, stdout: directory.appendingPathComponent("unused.stdout"), stderr: directory.appendingPathComponent("unused.stderr"),
            timeout: .greatestFiniteMagnitude, maxLogBytes: .max, jobID: parent, cancellation: token,
            environmentOverrides: environment, inheritIO: true, startSuspended: true,
            onStart: { group in
                try channel.send(ShellBridgeReply(processGroupID: group))
                while true {
                    guard let registered = try channel.receive(ShellBridgeReply.self, timeout: 10), registered.ok else {
                        throw SandboxError("shell process group registration was not acknowledged")
                    }
                    if registered.cancelled { token.cancel() }
                    if registered.processGroupID == group { break }
                    guard registered.cancelled else { throw SandboxError("invalid shell process group acknowledgement") }
                }
                monitor.resume(); monitoring = true
                if let startNotification {
                    let notification = FileHandle(fileDescriptor: startNotification, closeOnDealloc: false)
                    try notification.write(contentsOf: Data([1])); try notification.close()
                }
            })
        monitor.cancel(); queue.sync {}
        try channel.send(ShellBridgeReply(outcome: outcome))
        while let reply = try channel.receive(ShellBridgeReply.self, timeout: 10) {
            if !reply.cancelled { break }
        }
        if outcome.reason == .launchFailed {
            FileHandle.standardError.write(Data((outcome.launchError ?? "shell could not be started").utf8) + Data([10]))
            return 1
        }
        return outcome.reason == .exited ? (outcome.exitCode ?? 1) : 128 + (outcome.terminationSignal ?? SIGTERM)
    }
}
