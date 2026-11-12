import Foundation
import Darwin
import SandboxCore
import CryptoKit
import Darwin

public struct UncertainExecution: Error, CustomStringConvertible {
    public let result: NativeResult
    public var description: String {
        let base = "process group \(result.outcome.processID) cleanup unconfirmed"
        guard let diagnostics = result.outcome.cleanupDiagnostics else { return base }
        if let code = diagnostics.finalProbeError {
            return "\(base); probe errno \(code) (\(String(cString: strerror(code)))); \(diagnostics.probes) probes"
        }
        return "\(base); group still present after \(diagnostics.probes) probes"
    }
}

public struct ExecutionCounts: Codable, Equatable {
    public var parallelRunning = 0
    public var parallelWaiting = 0
    public var serialRunning = 0
    public var serialWaiting = 0
    public init(parallelRunning: Int = 0, parallelWaiting: Int = 0, serialRunning: Int = 0, serialWaiting: Int = 0) {
        self.parallelRunning = parallelRunning; self.parallelWaiting = parallelWaiting
        self.serialRunning = serialRunning; self.serialWaiting = serialWaiting
    }
    public var total: Int { parallelRunning + parallelWaiting + serialRunning + serialWaiting }
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(parallelRunning: lhs.parallelRunning + rhs.parallelRunning, parallelWaiting: lhs.parallelWaiting + rhs.parallelWaiting,
             serialRunning: lhs.serialRunning + rhs.serialRunning, serialWaiting: lhs.serialWaiting + rhs.serialWaiting)
    }
}

/// Policy-selected serial tasks share one slot. Parallel tasks have independent
/// durable leases. Every path still uses App Sandbox and fail-closed recovery.
public final class ExecutionScheduler {
    private let serialLane = NSCondition()
    private var serialWaiters: [String] = []
    private var serialBusy = false
    private var reservation: ClusterReservation?
    public let taskPolicy: TaskPolicy
    private let nodeLease: FileLease
    private let marker: URL
    private let parallelMarkers: URL
    private let stateLock = NSLock()
    private var pending = 0
    private struct CountedTask {
        let ownerID: String?
        var parallel: Bool
        var running = false
        var delegated = false
        var agentSession = false
        var leaseID: String?
        var counts: ExecutionCounts {
            if parallel { return running ? ExecutionCounts(parallelRunning: 1) : ExecutionCounts(parallelWaiting: 1) }
            return running ? ExecutionCounts(serialRunning: 1) : ExecutionCounts(serialWaiting: 1)
        }
    }
    private var countedTasks: [UUID: CountedTask] = [:]
    private var registrations: [ObjectIdentifier: UUID] = [:]
    private var quarantine: String?
    private let auditURL: URL
    private let auditLock = NSLock()
    private var auditWarningPrinted = false
    private let thermalState: () -> ProcessInfo.ThermalState
    public init(coordinationDirectory: URL = Paths.coordination, taskPolicy: TaskPolicy = TaskPolicy(),
                thermalState: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }) throws {
        self.thermalState = thermalState
        try taskPolicy.validate(); self.taskPolicy = taskPolicy
        try SafeFiles.secureDirectory(coordinationDirectory)
        nodeLease = try FileLease(coordinationDirectory.appendingPathComponent("daemon.lock"))
        marker = coordinationDirectory.appendingPathComponent("active-lease.json")
        auditURL = coordinationDirectory.appendingPathComponent("scheduler_events.jsonl")
        parallelMarkers = coordinationDirectory.appendingPathComponent("parallel_leases")
        try SafeFiles.secureDirectory(parallelMarkers)
        let staleParallel = try FileManager.default.contentsOfDirectory(atPath: parallelMarkers.path)
        if FileManager.default.fileExists(atPath: marker.path) || !staleParallel.isEmpty {
            quarantine = "prior execution marker exists; inspect processes and GPU before operator recovery"
        }
    }
    private func audit(_ event: String, lease: String, parallel: Bool, command: NativeCommand?, ownerID: String?, parentID: String?, outcome: ProcessOutcome? = nil, queueWaitSeconds: Double? = nil) {
        auditLock.lock(); defer { auditLock.unlock() }
        do {
            var entry: [String: String] = ["event": event, "leaseID": lease, "lane": parallel ? "parallel" : "serial",
                "monotonicNanoseconds": String(DispatchTime.now().uptimeNanoseconds), "recordedAt": ISO8601DateFormatter().string(from: Date())]
            entry["ownerID"] = ownerID; entry["parentLeaseID"] = parentID
            if let queueWaitSeconds { entry["queueWaitSeconds"] = String(queueWaitSeconds) }
            entry["program"] = command?.argv.first
            if let command { entry["argvSHA256"] = SHA256.hash(data: Data(command.argv.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined() }
            if let outcome { entry["outcome"] = outcome.reason.rawValue; entry["processGroupGone"] = String(outcome.processGroupGone) }
            let fd = open(auditURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SandboxError("cannot open scheduler audit") }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid() else { throw SandboxError("unsafe scheduler audit file") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: JSON.data(entry) + Data([10]))
        } catch {
            // Diagnostic only: never mislabel a successfully cleaned execution
            // as failed because its optional trace could not be written.
            if !auditWarningPrinted {
                auditWarningPrinted = true
                FileHandle.standardError.write(Data("scheduler audit unavailable: \(error)\n".utf8))
            }
        }
    }
    public var recoveryReason: String? {
        stateLock.lock(); defer { stateLock.unlock() }; return quarantine
    }
    public var pendingCount: Int { stateLock.lock(); defer { stateLock.unlock() }; return pending }
    public func reserveSerial(taskID: String) -> ClusterReservation? {
        serialLane.lock(); defer { serialLane.unlock() }
        if let current = reservation, current.expiresAt < Date() { reservation = nil; serialBusy = false; serialLane.broadcast() }
        guard !serialBusy, serialWaiters.isEmpty, recoveryReason == nil, thermalState() != .critical else { return nil }
        let value = ClusterReservation(id: UUID().uuidString.lowercased(), taskID: taskID, expiresAt: Date(timeIntervalSinceNow: 30))
        reservation = value; serialBusy = true; return value
    }
    public func releaseReservation(_ id: String) {
        serialLane.lock(); defer { serialLane.unlock() }
        if reservation?.id == id { reservation = nil; serialBusy = false; serialLane.broadcast() }
    }
    public var serialSlotAvailable: Bool {
        serialLane.lock(); defer { serialLane.unlock() }
        return !serialBusy && serialWaiters.isEmpty && thermalState() != .critical && recoveryReason == nil
    }
    /// Include accepted top-level work even before its dispatch worker starts.
    /// run() consumes the registration, so the parent is never counted twice.
    public func registerPending(_ token: CancellationToken, ownerID: String, parallel: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        let key = ObjectIdentifier(token)
        precondition(registrations[key] == nil)
        let id = UUID(); registrations[key] = id
        countedTasks[id] = CountedTask(ownerID: ownerID, parallel: parallel)
    }
    public func discardPending(_ token: CancellationToken) {
        stateLock.lock(); defer { stateLock.unlock() }
        if let id = registrations.removeValue(forKey: ObjectIdentifier(token)) { countedTasks.removeValue(forKey: id) }
    }
    public var counts: (total: ExecutionCounts, byOwner: [String: ExecutionCounts]) {
        stateLock.lock(); defer { stateLock.unlock() }
        var total = ExecutionCounts(), byOwner: [String: ExecutionCounts] = [:]
        for task in countedTasks.values {
            if !task.delegated || !task.running { total = total + task.counts }
            if let owner = task.ownerID { byOwner[owner] = byOwner[owner, default: ExecutionCounts()] + task.counts }
        }
        return (total, byOwner)
    }
    private func finishCounting(_ id: UUID) {
        stateLock.lock(); countedTasks.removeValue(forKey: id); stateLock.unlock()
    }
    public func requireInspection(_ reason: String) throws {
        stateLock.lock(); defer { stateLock.unlock() }; quarantine = reason
        if !FileManager.default.fileExists(atPath: marker.path) {
            try SafeFiles.write(["pid": String(getpid()), "state": "inspection-required", "reason": reason], to: marker)
        }
    }
    public func acknowledgeRecovery(confirmed: Bool, note: String, beforeResume: () throws -> Void = {}) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard quarantine != nil else { throw SandboxError("node is not quarantined") }
        guard confirmed, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.utf8.count <= 4096,
              countedTasks.values.allSatisfy({ !$0.running || ($0.agentSession && $0.parallel && !$0.delegated) }) else {
            throw SandboxError("recovery needs no running task commands, explicit operator confirmation and a note")
        }
        let liveLeases = Set(countedTasks.values.filter(\.running).compactMap(\.leaseID))
        // 恢复失败时仍保留持久隔离标记；正在运行的 Agent 主会话租约不得移走。
        if !FileManager.default.fileExists(atPath: marker.path) {
            try SafeFiles.write(["pid": String(getpid()), "state": "inspection-required", "reason": quarantine!], to: marker)
        }
        try beforeResume()
        let directory = marker.deletingLastPathComponent().appendingPathComponent("recovery_history")
        try SafeFiles.secureDirectory(directory)
        let id = UUID().uuidString.lowercased()
        try SafeFiles.write(["note": note, "priorReason": quarantine ?? "none",
                             "recordedAt": ISO8601DateFormatter().string(from: Date())], to: directory.appendingPathComponent(id + ".json"))
        for file in try FileManager.default.contentsOfDirectory(at: parallelMarkers, includingPropertiesForKeys: nil) {
            if liveLeases.contains(file.deletingPathExtension().lastPathComponent) { continue }
            try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent(id + "_parallel_" + file.lastPathComponent))
        }
        try FileManager.default.moveItem(at: marker, to: directory.appendingPathComponent(id + "_lease.json"))
        quarantine = nil
    }
    public func run(command: NativeCommand? = nil, taskPolicy: TaskPolicy? = nil, parallel: Bool? = nil, cancellation: CancellationToken = CancellationToken(), deadlineUptimeNanoseconds: UInt64? = nil, ownerID: String? = nil, parentID: String? = nil,
                    delegation: ClusterDelegation? = nil, reservationID: String? = nil, onRemoteStarted: () throws -> Void = {},
                    _ launch: (String) throws -> NativeResult) throws -> NativeResult {
        try taskPolicy?.validate()
        let parallel = parallel ?? (command?.agentSession == true || (taskPolicy ?? self.taskPolicy).allowsParallel(command))
        stateLock.lock()
        guard pending < 64 else { stateLock.unlock(); throw SandboxError("execution queue full") }
        pending += 1
        let countID = registrations.removeValue(forKey: ObjectIdentifier(cancellation)) ?? UUID()
        if countedTasks[countID] == nil { countedTasks[countID] = CountedTask(ownerID: ownerID, parallel: parallel) }
        countedTasks[countID]?.parallel = parallel
        countedTasks[countID]?.agentSession = command?.agentSession == true
        stateLock.unlock()
        defer {
            stateLock.lock(); pending -= 1
            countedTasks.removeValue(forKey: countID)
            stateLock.unlock()
        }
        let queued = DispatchTime.now().uptimeNanoseconds
        cancellation.queueWait.setWaiting(true)
        defer { cancellation.queueWait.setWaiting(false) }
        func checkAdmission() throws {
            guard !cancellation.isCancelled else { throw SandboxError("cancelled before grant; no process launched") }
            if let deadline = deadlineUptimeNanoseconds {
                guard DispatchTime.now().uptimeNanoseconds + 100_000_000 < deadline else {
                    throw SandboxError("deadline expired in queue; no process launched")
                }
            }
        }
        func perform() throws -> NativeResult {
            // Remove the running count BEFORE releasing the serial slot, so a
            // snapshot can never report two serial tasks running during handoff.
            defer { finishCounting(countID) }
            // Cooldown delays admission, not completion or cleanup. No durable
            // execution marker exists until the task actually receives a lease.
            let id = UUID().uuidString.lowercased()
            let executionMarker = parallel ? parallelMarkers.appendingPathComponent(id + ".json") : marker
            while true {
                try checkAdmission()
                if thermalState() == .critical { Thread.sleep(forTimeInterval: 0.1); continue }
                stateLock.lock()
                if quarantine != nil { stateLock.unlock(); Thread.sleep(forTimeInterval: 0.1); continue }
                do {
                    guard cancellation.beginExecution() else { throw SandboxError("cancelled before grant; no process launched") }
                    try SafeFiles.write(["leaseID": id, "pid": String(getpid()), "state": "granted",
                                         "recordedAt": ISO8601DateFormatter().string(from: Date())], to: executionMarker)
                    countedTasks[countID]?.running = true; countedTasks[countID]?.leaseID = id
                } catch { stateLock.unlock(); throw error }
                stateLock.unlock()
                break
            }
            let wait = Double(DispatchTime.now().uptimeNanoseconds - queued) / 1e9
            cancellation.queueWait.setWaiting(false)
            audit("granted", lease: id, parallel: parallel, command: command, ownerID: ownerID, parentID: parentID, queueWaitSeconds: wait)
            do {
                var result = try launch(id)
                guard result.leaseID == id else { throw SandboxError("execution lease mismatch") }
                result.queueWaitSeconds = wait
                guard !result.outcome.requiresInspection else {
                    throw UncertainExecution(result: result)
                }
                try FileManager.default.removeItem(at: executionMarker)
                audit("finished", lease: id, parallel: parallel, command: command, ownerID: ownerID, parentID: parentID, outcome: result.outcome)
                return result
            } catch {
                audit("failed", lease: id, parallel: parallel, command: command, ownerID: ownerID, parentID: parentID)
                stateLock.lock(); quarantine = String(describing: error); stateLock.unlock()
                // Keep the journal on every ambiguous failure, including broken IPC.
                throw error
            }
        }
        func remote(_ delegation: ClusterDelegation) throws -> NativeResult {
            let wait = Double(DispatchTime.now().uptimeNanoseconds - queued) / 1e9
            var result = try delegation.wait {
                stateLock.lock(); countedTasks[countID]?.running = true; countedTasks[countID]?.delegated = true; stateLock.unlock()
                cancellation.queueWait.setWaiting(false)
                try onRemoteStarted()
            }
            result.queueWaitSeconds += wait
            return result
        }
        // Parallel tasks never enter this queue. Cancelled waiters can retire
        // immediately instead of blocking behind an unrelated running task.
        if parallel { return try perform() }
        if let reservationID {
            serialLane.lock()
            guard let value = reservation, value.id == reservationID, value.expiresAt >= Date() else {
                serialLane.unlock(); throw SandboxError("serial reservation expired or mismatched")
            }
            reservation = nil; serialLane.unlock()
            defer { serialLane.lock(); serialBusy = false; serialLane.broadcast(); serialLane.unlock() }
            return try perform()
        }
        let ticket = UUID().uuidString
        serialLane.lock(); serialWaiters.append(ticket)
        while serialBusy || serialWaiters.first != ticket {
            if let reservation, reservation.expiresAt < Date() {
                self.reservation = nil; serialBusy = false; serialLane.broadcast()
                continue
            }
            if delegation?.isClaimed == true {
                serialWaiters.removeAll { $0 == ticket }; serialLane.broadcast(); serialLane.unlock()
                return try remote(delegation!)
            }
            do { try checkAdmission() }
            catch {
                if let delegation, !delegation.startLocal() {
                    serialWaiters.removeAll { $0 == ticket }; serialLane.broadcast(); serialLane.unlock()
                    return try remote(delegation)
                }
                serialWaiters.removeAll { $0 == ticket }; serialLane.broadcast(); serialLane.unlock()
                throw error
            }
            _ = serialLane.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        if let delegation, !delegation.startLocal() {
            serialWaiters.removeAll { $0 == ticket }; serialLane.broadcast(); serialLane.unlock()
            return try remote(delegation)
        }
        serialWaiters.removeFirst(); serialBusy = true; serialLane.unlock()
        defer { serialLane.lock(); serialBusy = false; serialLane.broadcast(); serialLane.unlock() }
        return try perform()
    }
}
