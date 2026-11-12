import Foundation
import SandboxCore
import SandboxRuntime

public final class LoopbackForwardRegistry {
    private final class Entry {
        let id: String, instanceID: String, owner: String
        let port: Int
        var expires: TimeInterval
        var connections: [String: ClusterPortForward] = [:]
        var pending = Set<String>()
        var retryAfter: [String: TimeInterval] = [:]
        var nodeErrors: [String: String] = [:]
        var error: String?
        init(id: String, instanceID: String, owner: String, port: Int, expires: TimeInterval) {
            self.id = id; self.instanceID = instanceID; self.owner = owner; self.port = port; self.expires = expires
        }
    }
    private let configuration: ClusterConfiguration
    private let transport: ClusterTransport
    private let lifetime: TimeInterval
    private let lock = NSLock()
    private let work = DispatchGroup()
    private var entries: [String: Entry] = [:]
    private var closed = false
    private var timer: DispatchSourceTimer?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public init(configuration: ClusterConfiguration?, transport: ClusterTransport, lifetime: TimeInterval = 60) throws {
        guard lifetime.isFinite, lifetime > 0 else { throw SandboxError("invalid forwarding lease duration") }
        self.configuration = configuration ?? ClusterConfiguration(localNodeID: "local", nodes: [])
        self.transport = transport; self.lifetime = lifetime
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "metal-sandbox.forward-expiry"))
        timer.schedule(deadline: .now() + lifetime, repeating: min(1, lifetime))
        timer.setEventHandler { [weak self] in self?.expire() }
        self.timer = timer; timer.resume()
    }

    public func open(id: String, instanceID: String, owner: String, port: Int) throws -> LoopbackForwardInfo {
        guard UUID(uuidString: id) != nil else { throw SandboxError("forward ID must be a UUID") }
        try LoopbackPort.check(port)
        lock.lock()
        if let entry = entries[id] {
            let matches = entry.instanceID == instanceID && entry.port == port && entry.owner == owner
            lock.unlock()
            guard matches else { throw SandboxError("forward ID belongs to a different endpoint") }
            return try status(id: id, instanceID: instanceID)
        }
        guard !closed, !entries.values.contains(where: { $0.port == port }) else {
            lock.unlock(); throw SandboxError("forwarding is closed or this port already has a lease")
        }
        let entry = Entry(id: id, instanceID: instanceID, owner: owner, port: port, expires: now + lifetime)
        entries[id] = entry
        work.enter()
        lock.unlock()
        defer { work.leave() }
        do {
            if owner != configuration.localNodeID {
                guard let node = configuration.nodes.first(where: { $0.id == owner }) else { throw SandboxError("unknown forwarding node: \(owner)") }
                let connection = try transport.forward(node: node, sourcePort: port, listenPort: port)
                lock.lock()
                guard !closed, entries[id] === entry, entry.error == nil, entry.expires > now else {
                    lock.unlock(); connection.close(); throw SandboxError("forwarding lease closed during connection")
                }
                entry.connections[owner] = connection
                lock.unlock()
            }
            return try status(id: id, instanceID: instanceID)
        } catch {
            close(id: id, instanceID: instanceID)
            throw error
        }
    }

    public func status(id: String, instanceID: String) throws -> LoopbackForwardInfo {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id], entry.instanceID == instanceID else { throw SandboxError("unknown forwarding lease") }
        try requireActive(entry)
        try LoopbackPort.check(entry.port)
        reconnectOwner(entry)
        entry.expires = now + lifetime
        let ready = [configuration.localNodeID] + entry.connections.filter { $0.value.isRunning }.map(\.key)
        return LoopbackForwardInfo(id: id, instanceID: instanceID, port: entry.port, ownerNodeID: entry.owner,
                                   readyNodeIDs: ready.sorted(), expiresAt: Date(timeIntervalSinceNow: lifetime), nodeErrors: entry.nodeErrors)
    }

    private func requireActive(_ entry: Entry) throws {
        if let error = entry.error { throw SandboxError(error) }
        guard !closed, entry.expires > now else { throw SandboxError("forwarding lease expired") }
    }

    // Caller holds the lock.
    private func reconnectOwner(_ entry: Entry) {
        guard entry.owner != configuration.localNodeID, entry.connections[entry.owner]?.isRunning != true else { return }
        if entry.nodeErrors[entry.owner] == nil { entry.nodeErrors[entry.owner] = "forwarding connection to \(entry.owner) was lost; reconnecting" }
        guard !entry.pending.contains(entry.owner), (entry.retryAfter[entry.owner] ?? 0) <= now,
              let node = configuration.nodes.first(where: { $0.id == entry.owner }) else { return }
        connect(entry, node: node)
    }

    // Caller holds the lock.
    private func connect(_ entry: Entry, node: ClusterNode) {
        let nodeID = node.id
        entry.pending.insert(nodeID)
        let old = entry.connections.removeValue(forKey: nodeID)
        work.enter()
        DispatchQueue.global().async { [self] in
            defer { work.leave() }
            do {
                if let old, !old.close() { throw SandboxError("previous forwarding process cleanup is unconfirmed") }
                let connection = try transport.forward(node: node, sourcePort: entry.port, listenPort: entry.port)
                lock.lock()
                if !closed, entries[entry.id] === entry, entry.error == nil, entry.expires > now {
                    entry.connections[nodeID] = connection
                    entry.pending.remove(nodeID); entry.nodeErrors.removeValue(forKey: nodeID)
                    lock.unlock()
                } else { lock.unlock(); connection.close() }
            } catch {
                lock.lock(); defer { lock.unlock() }
                if entries[entry.id] === entry {
                    if let old, old.isRunning { entry.connections[nodeID] = old }
                    entry.pending.remove(nodeID); entry.retryAfter[nodeID] = now + 10
                    entry.nodeErrors[nodeID] = String(describing: error)
                }
            }
        }
    }

    // 未准备好的节点保留在后台建立连接，调度线程继续检查原节点和其他任务。
    public func prepare(instanceID: String, ids: [String], nodeID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var ready = true
        for id in ids {
            guard let entry = entries[id], entry.instanceID == instanceID,
                  (try? requireActive(entry)) != nil,
                  configuration.permitsDispatch(from: entry.owner, to: nodeID) else { return false }
            if nodeID == configuration.localNodeID { continue }
            if entry.connections[nodeID]?.isRunning == true, entry.nodeErrors[nodeID] == nil { continue }
            ready = false
            guard !entry.pending.contains(nodeID), (entry.retryAfter[nodeID] ?? 0) <= now,
                  let node = configuration.nodes.first(where: { $0.id == nodeID }) else { continue }
            connect(entry, node: node)
        }
        return ready
    }

    @discardableResult public func close(id: String, instanceID: String) -> Bool {
        lock.lock()
        guard let entry = entries[id] else { lock.unlock(); return true }
        guard entry.instanceID == instanceID else { lock.unlock(); return false }
        entry.error = "forwarding lease is closing"
        let connections = Array(entry.connections.values)
        lock.unlock()
        let confirmed = connections.map { $0.close() }.allSatisfy { $0 }
        lock.lock(); defer { lock.unlock() }
        if entries[id] === entry {
            if confirmed { entries.removeValue(forKey: id) }
            else { entry.error = "forwarding process cleanup is unconfirmed" }
        }
        return confirmed
    }

    @discardableResult public func close(instanceID: String) -> Bool {
        lock.lock(); let ids = entries.values.filter { $0.instanceID == instanceID }.map(\.id); lock.unlock()
        return ids.map { close(id: $0, instanceID: instanceID) }.allSatisfy { $0 }
    }

    private func expire() {
        lock.lock()
        var connections: [ClusterPortForward] = []
        for entry in entries.values where entry.expires <= now && entry.error == nil {
            entry.error = "forwarding lease expired"
            connections += entry.connections.values
        }
        if !closed { for entry in entries.values where entry.error == nil { reconnectOwner(entry) } }
        lock.unlock()
        connections.forEach { $0.close() }
    }

    public func shutdown() {
        timer?.cancel(); timer = nil
        lock.lock(); closed = true
        let connections = entries.values.flatMap { $0.connections.values }
        entries.removeAll(); lock.unlock()
        connections.forEach { $0.close() }
        work.wait()
    }
    deinit { timer?.cancel() }
}
