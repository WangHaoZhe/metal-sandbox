import Foundation
import SandboxCore

/// Local handoff state. SSH only transports these operations; it never chooses a node.
public final class ClusterDelegation {
    public let task: ClusterTask
    private let condition = NSCondition()
    private var claimed = false
    private var local = false
    private var update: ClusterTaskUpdate?
    private var started = false
    public init(task: ClusterTask) { self.task = task }
    public func claim() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !claimed, !local else { return false }; claimed = true; return true
    }
    public func startLocal() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !claimed else { return false }; local = true; return true
    }
    public var isClaimed: Bool { condition.lock(); defer { condition.unlock() }; return claimed }
    public var canClaim: Bool { condition.lock(); defer { condition.unlock() }; return !claimed && !local }
    public func markStarted() throws {
        condition.lock(); defer { condition.unlock() }
        guard claimed else { throw SandboxError("cluster task has not been claimed") }
        if !started { started = true; condition.broadcast() }
    }
    public func complete(_ value: ClusterTaskUpdate) throws {
        condition.lock(); defer { condition.unlock() }
        guard claimed, value.taskID == task.id else { throw SandboxError("unclaimed cluster completion") }
        guard update == nil else { return }
        guard ["finished", "failed"].contains(value.state) else { throw SandboxError("nonterminal cluster completion") }
        update = value; condition.broadcast()
    }
    public func wait(onStarted: () throws -> Void = {}) throws -> NativeResult {
        condition.lock()
        while !started && update == nil { condition.wait() }
        condition.unlock()
        let startError: Error?
        do { try onStarted(); startError = nil } catch { startError = error }
        condition.lock(); defer { condition.unlock() }
        while update == nil { condition.wait() }
        if let startError { throw startError }
        guard let result = update?.result, update?.state == "finished" else { throw SandboxError(update?.error ?? "remote execution failed") }
        guard !result.outcome.requiresInspection else { throw UncertainExecution(result: result) }
        return result
    }
}

public final class ClusterTaskQueue {
    private let lock = NSLock()
    private var offers: [String: (ClusterDelegation, CancellationToken)] = [:]
    private let directory: URL?
    public init(directory: URL? = nil) throws {
        self.directory = directory
        if let directory { try SafeFiles.secureDirectory(directory) }
    }
    public var hasUnfinishedClaims: Bool {
        get throws {
            guard let directory else { return false }
            return try !FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty
        }
    }
    public func hasClaim(instanceID: String) throws -> Bool {
        guard let directory else { return false }
        for path in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if try SafeFiles.read(ClusterTask.self, from: path).instanceID == instanceID { return true }
        }
        return false
    }
    public func archiveClaims(to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard let directory else { return }
        try SafeFiles.secureDirectory(destination)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if offers[url.deletingPathExtension().lastPathComponent] != nil { continue }
            try FileManager.default.moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
        }
    }
    public func add(_ task: ClusterTask, cancellation: CancellationToken) -> ClusterDelegation {
        let delegation = ClusterDelegation(task: task)
        lock.lock(); offers[task.id] = (delegation, cancellation); lock.unlock(); return delegation
    }
    public func remove(_ id: String) { lock.lock(); offers.removeValue(forKey: id); lock.unlock() }
    public func pending() -> [ClusterTask] {
        lock.lock(); defer { lock.unlock() }
        return offers.values.filter { $0.0.canClaim && !$0.1.isCancelled }.map { $0.0.task }.sorted { $0.id < $1.id }
    }
    public func claim(_ id: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let value = offers[id], !value.1.isCancelled, value.0.canClaim else { return false }
        if let directory { try SafeFiles.write(value.0.task, to: directory.appendingPathComponent(id + ".json")) }
        if value.0.claim() { return true }
        if let directory { try FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".json")) }
        return false
    }
    public func cancelled(_ id: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let value = offers[id] else { throw SandboxError("unknown cluster task") }; return value.1.isCancelled
    }
    public func isClaimed(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return offers[id]?.0.isClaimed == true
    }
    public func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return offers[id] != nil
    }
    public func complete(_ update: ClusterTaskUpdate) throws {
        lock.lock(); let value = offers[update.taskID]; lock.unlock()
        guard let value, value.0.isClaimed, ["finished", "failed"].contains(update.state) else { throw SandboxError("invalid cluster completion") }
        if let directory, update.cleanupConfirmed == true {
            let url = directory.appendingPathComponent(update.taskID + ".json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try value.0.complete(update)
    }
    public func started(_ id: String) throws {
        lock.lock(); let value = offers[id]; lock.unlock()
        guard let value else { throw SandboxError("unknown cluster task") }; try value.0.markStarted()
    }
}
