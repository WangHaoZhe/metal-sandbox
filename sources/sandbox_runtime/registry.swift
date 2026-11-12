import Foundation
import SandboxCore

public enum SandboxOperation: String, Codable, CaseIterable { case read, write, export, exec, stop }
public struct SandboxHandle: Codable {
    public let instanceID: String
    public let generation: String
    public let capability: String
    public init(instanceID: String, generation: String, capability: String) {
        self.instanceID = instanceID; self.generation = generation; self.capability = capability
    }
}

/// Management authorization core used by the public Unix RPC server.
/// UID checks alone never grant an instance or operation permission.
public final class SandboxRegistry {
    private final class Instance {
        let lock = NSCondition()
        var executions = 0
        let files = NSRecursiveLock()
        let session: SandboxSession
        let generation: String
        var capabilities: [String: Set<SandboxOperation>]
        init(session: SandboxSession, generation: String, capabilities: [String: Set<SandboxOperation>]) {
            self.session = session; self.generation = generation; self.capabilities = capabilities
        }
    }
    private let lock = NSRecursiveLock()
    private var instances: [String: Instance] = [:]
    private var retired = Set<String>()
    public init() {}
    public func validate(_ handle: SandboxHandle, operation: SandboxOperation) throws {
        lock.lock(); defer { lock.unlock() }; _ = try authorize(handle, operation)
    }

    // Trusted controller API only. The Agent receives a scoped client, not a
    // factory, registry reference, app path, policy selector or signing options.
    public func register(_ session: SandboxSession, reactivating: Bool = false) throws -> SandboxHandle {
        lock.lock(); defer { lock.unlock() }
        guard instances[session.id] == nil, reactivating || !retired.contains(session.id) else {
            throw SandboxError("duplicate or retired application identity; create a fresh instance")
        }
        let generation = UUID().uuidString.lowercased(), token = UUID().uuidString.lowercased()
        instances[session.id] = Instance(session: session, generation: generation,
                                        capabilities: [token: Set(SandboxOperation.allCases)])
        return SandboxHandle(instanceID: session.id, generation: generation, capability: token)
    }
    public func grant(_ owner: SandboxHandle, operations: Set<SandboxOperation>) throws -> SandboxHandle {
        lock.lock(); defer { lock.unlock() }
        _ = try authorize(owner, .stop)
        guard let rights = instances[owner.instanceID]?.capabilities[owner.capability], operations.isSubset(of: rights) else {
            throw SandboxError("cannot amplify capability rights")
        }
        let token = UUID().uuidString.lowercased()
        instances[owner.instanceID]!.capabilities[token] = operations
        return SandboxHandle(instanceID: owner.instanceID, generation: owner.generation, capability: token)
    }
    private func authorize(_ handle: SandboxHandle, _ operation: SandboxOperation) throws -> SandboxSession {
        guard let instance = instances[handle.instanceID], instance.generation == handle.generation,
              instance.capabilities[handle.capability]?.contains(operation) == true else {
            throw SandboxError("unknown, stale or insufficient sandbox capability")
        }
        return instance.session
    }
    fileprivate func access<T>(_ handle: SandboxHandle, _ operation: SandboxOperation, _ body: (SandboxSession) throws -> T) throws -> T {
        lock.lock()
        let instance = instances[handle.instanceID]
        lock.unlock()
        guard let instance else { throw SandboxError("unknown, stale or insufficient sandbox capability") }
        // Reads may overlap execution, but never mutation/export or retirement.
        // Keep the execution lock separate from the short-lived file access lock.
        if operation != .read {
            if operation == .exec {
                instance.lock.lock(); instance.executions += 1; instance.lock.unlock()
            }
            else {
                instance.lock.lock()
                guard instance.executions == 0 else { instance.lock.unlock(); throw SandboxError("instance busy; file operation was not applied") }
            }
        }
        defer {
            if operation == .exec {
                instance.lock.lock(); instance.executions -= 1; instance.lock.broadcast(); instance.lock.unlock()
            } else if operation != .read { instance.lock.unlock() }
        }
        if operation != .exec { instance.files.lock() }
        defer { if operation != .exec { instance.files.unlock() } }
        lock.lock()
        let session: SandboxSession
        do { session = try authorize(handle, operation) }
        catch { lock.unlock(); throw error }
        lock.unlock()
        return try body(session)
    }
    fileprivate func stop(_ handle: SandboxHandle) throws {
        lock.lock()
        let session: SandboxSession
        do { session = try authorize(handle, .stop) }
        catch { lock.unlock(); throw error }
        let instance = instances[handle.instanceID]!
        // Revoke first: a failed cleanup must not allow further execution.
        instances.removeValue(forKey: handle.instanceID)
        retired.insert(handle.instanceID)
        lock.unlock()
        instance.lock.lock(); defer { instance.lock.unlock() }
        while instance.executions > 0 { instance.lock.wait() }
        instance.files.lock(); defer { instance.files.unlock() }
        try session.close()
    }
    public func client(_ handle: SandboxHandle) -> ScopedSandboxClient { ScopedSandboxClient(registry: self, handle: handle) }
}

public final class ScopedSandboxClient: SandboxSession {
    private let registry: SandboxRegistry
    private let handle: SandboxHandle
    private var didClose = false
    public var id: String { handle.instanceID }
    fileprivate init(registry: SandboxRegistry, handle: SandboxHandle) { self.registry = registry; self.handle = handle }
    public func read(_ path: String) throws -> WorkspaceFile { try registry.access(handle, .read) { try $0.read(path) } }
    public func workspaceLocation(_ path: String) throws -> String { try registry.access(handle, .read) { try $0.workspaceLocation(path) } }
    public func trajectory(session: String?, after: String?) throws -> TrajectoryReply {
        try registry.access(handle, .read) { try $0.trajectory(session: session, after: after) }
    }
    public func listDirectory(_ path: String, after: String?) throws -> WorkspaceDirectory {
        try registry.access(handle, .read) { try $0.listDirectory(path, after: after) }
    }
    public func write(_ file: WorkspaceFile) throws { try registry.access(handle, .write) { try $0.write(file) } }
    public func export() throws -> [WorkspaceFile] { try registry.access(handle, .export) { try $0.export() } }
    public func download(to url: URL, path: String?) throws {
        try registry.access(handle, path == nil ? .export : .read) { try $0.download(to: url, path: path) }
    }
    public func upload(from url: URL) throws {
        try registry.access(handle, .write) { try $0.upload(from: url) }
    }
    public func execute(_ command: NativeCommand) throws -> NativeResult { try registry.access(handle, .exec) { try $0.execute(command) } }
    public func execute(_ command: NativeCommand, cancellation: CancellationToken) throws -> NativeResult {
        try registry.access(handle, .exec) { try $0.execute(command, cancellation: cancellation) }
    }
    public func execute(_ command: NativeCommand, cancellation: CancellationToken, onGranted: () throws -> Void) throws -> NativeResult {
        try registry.access(handle, .exec) { try $0.execute(command, cancellation: cancellation, onGranted: onGranted) }
    }
    public func close() throws {
        if didClose { return }
        try registry.stop(handle); didClose = true
    }
}
