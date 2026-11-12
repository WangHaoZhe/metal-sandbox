import Foundation
import SandboxCore
import SandboxRuntime

public final class ClusterPlacement {
    private let lock = NSLock()
    private var reserved: [String: Int] = [:]
    public init() {}
    public func reserve(nodes: [ClusterNodeStatus], preferred: String? = nil, excluding: String? = nil) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let eligible = nodes.filter { $0.readyForExecution && $0.id != excluding && (preferred == nil || $0.id == preferred) && $0.instanceLimit > 0 }
        let candidates = eligible.filter { $0.status!.activeInstances < $0.instanceLimit - reserved[$0.id, default: 0] }
        guard let chosen = candidates.min(by: {
            let left = $0.status!.activeInstances + reserved[$0.id, default: 0]
            let right = $1.status!.activeInstances + reserved[$1.id, default: 0]
            return left == right ? $0.id < $1.id : left < right
        }) else {
            if !eligible.isEmpty { throw SandboxError("all eligible nodes have reached their active-instance limits", code: .instanceCapacityUnavailable) }
            throw SandboxError("no enabled and available cluster node")
        }
        reserved[chosen.id, default: 0] += 1; return chosen.id
    }
    public func release(_ id: String) { lock.lock(); reserved[id, default: 0] -= 1; precondition(reserved[id]! >= 0); lock.unlock() }
    public static func serialTarget(nodes: [ClusterNodeStatus], source: String) -> String? {
        guard let origin = nodes.first(where: { $0.id == source }), origin.readyForExecution, origin.permitsCrossNodeScheduling,
              (origin.status?.executionCounts.serialWaiting ?? 0) > 0 else { return nil }
        return nodes.filter { $0.id != source && $0.pool == origin.pool && $0.permitsCrossNodeScheduling
            && $0.readyForExecution && $0.status!.serialSlotAvailable == true }
            .min { $0.status!.activeInstances == $1.status!.activeInstances ? $0.id < $1.id : $0.status!.activeInstances < $1.status!.activeInstances }?.id
    }
    public static func pendingTarget(nodes: [ClusterNodeStatus], source: String) -> String? {
        let candidates = nodes.filter { $0.readyForExecution && $0.status!.serialSlotAvailable == true }
        if candidates.contains(where: { $0.id == source }) { return source }
        guard let origin = nodes.first(where: { $0.id == source }), origin.readyForExecution, origin.permitsCrossNodeScheduling else { return nil }
        return candidates.filter { $0.pool == origin.pool && $0.permitsCrossNodeScheduling }.min {
            $0.status!.activeInstances == $1.status!.activeInstances ? $0.id < $1.id : $0.status!.activeInstances < $1.status!.activeInstances
        }?.id
    }
}
