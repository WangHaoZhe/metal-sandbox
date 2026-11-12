import Foundation
import Darwin

public final class QueueWaitClock {
    private let lock = NSLock()
    private var started: UInt64?
    private var accumulated: Double = 0
    private var childWait: Double = 0
    public init() {}
    public func setWaiting(_ waiting: Bool) {
        lock.lock(); defer { lock.unlock() }
        if waiting && started == nil { started = DispatchTime.now().uptimeNanoseconds }
        if !waiting, let start = started {
            accumulated += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            started = nil
        }
    }
    public func setChildWait(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        childWait = max(childWait, seconds)
    }
    public var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return accumulated + childWait + (started.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1e9 } ?? 0)
    }
}

public final class CancellationToken {
    public let queueWait = QueueWaitClock()
    private let lock = NSLock()
    private var cancelled = false
    private var executionStarted = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func beginExecution() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        executionStarted = true; return true
    }
    public func cancelBeforeExecution() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !executionStarted else { return false }
        cancelled = true; return true
    }
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
}

/// Process-group containment only. A hostile child can escape its group or attack
/// same-UID processes. This is deliberately NOT presented as a security sandbox.
public enum ProcessRunner {
    public static func run(argv: [String], workingDirectory: URL, home: URL, temporary: URL,
                           stdout: URL, stderr: URL, timeout: Double, maxLogBytes: Int,
                           jobID: String, cancellation: CancellationToken,
                           environmentOverrides: [String: String] = [:], inheritIO: Bool = false,
                           excludedSeconds: () -> Double = { 0 },
                           startSuspended: Bool = false,
                           onStart: (Int32) throws -> Void = { _ in }) throws -> ProcessOutcome {
        guard !argv.isEmpty else { throw SandboxError("empty argv") }
        if cancellation.isCancelled {
            return ProcessOutcome(processID: 0, reason: .cancelled, elapsedSeconds: 0, cleanupSeconds: 0)
        }
        let executable = argv[0].hasPrefix("/") ? argv[0] : workingDirectory.appendingPathComponent(argv[0]).standardizedFileURL.path
        let args = [executable] + argv.dropFirst()
        try SafeFiles.secureDirectory(home)
        try SafeFiles.secureDirectory(temporary)
        let cache = home.appendingPathComponent("cache")
        try SafeFiles.secureDirectory(cache)
        var values = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path, "TMPDIR": temporary.path + "/", "LANG": "en_US.UTF-8",
            "METAL_SANDBOX_JOB_ID": jobID, "WORKSPACE": workingDirectory.path,
            "CLANG_MODULE_CACHE_PATH": cache.path + "/clang",
            "SWIFT_MODULECACHE_PATH": cache.path + "/swift",
        ]
        // Only trusted callers supply these; candidate commands have no API for
        // importing the controller's environment or credentials.
        for (key, value) in environmentOverrides { values[key] = value }
        let environment = values.keys.sorted().map { "\($0)=\(values[$0]!)" }
        var arguments: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var env: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) }; env.forEach { free($0) } }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions), "spawn actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes), "spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path), "spawn chdir")
        if inheritIO {
            for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
                try check(posix_spawn_file_actions_adddup2(&actions, fd, fd), "inherit standard stream")
            }
        } else {
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "spawn stdin")
        let logFlags = O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW
        try check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdout.path, logFlags, 0o600), "spawn stdout")
        try check(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderr.path, logFlags, 0o600), "spawn stderr")
        }
        try check(posix_spawnattr_setpgroup(&attributes, 0), "spawn process group")
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask), "spawn signal mask")
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, sig) }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults), "spawn signal defaults")
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT | (startSuspended ? POSIX_SPAWN_START_SUSPENDED : 0))
        try check(posix_spawnattr_setflags(&attributes, flags), "spawn flags")

        let started = DispatchTime.now().uptimeNanoseconds
        var pid: pid_t = 0
        let spawnResult = arguments.withUnsafeMutableBufferPointer { argPtr in
            env.withUnsafeMutableBufferPointer { envPtr in
                posix_spawn(&pid, executable, &actions, &attributes, argPtr.baseAddress!, envPtr.baseAddress!)
            }
        }
        if spawnResult != 0 {
            return ProcessOutcome(processID: 0, reason: .launchFailed,
                elapsedSeconds: seconds(since: started), cleanupSeconds: 0,
                launchError: "spawn \(executable): \(String(cString: strerror(spawnResult)))")
        }
        do {
            try onStart(pid)
            if startSuspended, kill(pid, cancellation.isCancelled ? SIGKILL : SIGCONT) != 0 {
                throw SandboxError("cannot start or cancel registered child \(pid): \(String(cString: strerror(errno)))")
            }
        }
        catch {
            _ = kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            throw error
        }

        var status: Int32 = 0
        var forcedReason: ProcessOutcome.Reason?
        var terminationStarted: UInt64?
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0 {
                if errno == EINTR { continue }
                _ = kill(-pid, SIGKILL)
                throw SandboxError("waitpid failed for child \(pid): \(String(cString: strerror(errno)))")
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if forcedReason == nil {
                if cancellation.isCancelled { forcedReason = .cancelled }
                else if seconds(since: started, now: now) - excludedSeconds() >= timeout { forcedReason = .timedOut }
                else if !inheritIO && logSize(stdout) + logSize(stderr) > maxLogBytes { forcedReason = .outputLimit }
                if forcedReason != nil {
                    terminationStarted = now
                    _ = kill(-pid, SIGTERM)
                }
            } else if let terminationStarted, seconds(since: terminationStarted, now: now) >= 0.25 {
                _ = kill(-pid, SIGKILL)
            }
            usleep(20_000)
        }
        // A cooperative wrapper can exit as soon as cancellation is delivered,
        // before the polling loop observes the token. Do not report that race
        // as a successful command merely because waitpid won the final poll.
        if forcedReason == nil && cancellation.isCancelled { forcedReason = .cancelled }
        let elapsed = seconds(since: started)
        // Also clean up cooperative descendants left behind by a successful shell.
        let cleanupStart = DispatchTime.now().uptimeNanoseconds
        let cleanup = ProcessGroup.clean(pid)
        let signalNumber = status & 0x7f
        let exitCode: Int32? = signalNumber == 0 ? (status >> 8) & 0xff : nil
        if forcedReason == nil && !inheritIO && logSize(stdout) + logSize(stderr) > maxLogBytes { forcedReason = .outputLimit }
        var outcome = ProcessOutcome(processID: pid,
                              reason: forcedReason ?? (signalNumber == 0 ? .exited : .signalled),
                              exitCode: exitCode,
                              terminationSignal: signalNumber == 0 ? nil : signalNumber,
                              elapsedSeconds: elapsed, cleanupSeconds: seconds(since: cleanupStart), processGroupGone: cleanup.gone)
        outcome.cleanupDiagnostics = cleanup.diagnostics
        return outcome
    }

    private static func logSize(_ url: URL) -> Int {
        var st = stat()
        return lstat(url.path, &st) == 0 ? Int(max(0, st.st_size)) : 0
    }
    private static func check(_ result: Int32, _ context: String) throws {
        guard result == 0 else { throw SandboxError("\(context): \(String(cString: strerror(result)))") }
    }
    private static func seconds(since start: UInt64, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Double {
        Double(now - start) / 1_000_000_000
    }
}
