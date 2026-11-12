import Foundation
import SandboxCore

/// A compiled-in harness adapter. Scheduling, sandbox execution and private
/// file access remain in the runtime; installation/launch remain in setup.sh.
public protocol AgentHarness {
    var id: String { get }
    func shell(environment: [String: String]) -> String
    func toolEnvironment(_ environment: [String: String]) -> [String: String]
    func resources(helper: String) throws -> [String: Data]
    func environment(resources: URL) -> [String: String]
    func toolCommand(from event: Data) throws -> String
    func toolInvocation(command: String, helper: String) -> String
    func toolReply(to event: Data, command: String) throws -> Data
    func acceptsTrajectory(_ path: String) -> Bool
    func trajectories(entries: (String) throws -> [WorkspaceEntry]) throws -> [TrajectorySession]
}

public extension AgentHarness {
    func toolEnvironment(_ environment: [String: String]) -> [String: String] { environment }
    func toolInvocation(command: String, helper: String) -> String { command }
}

public enum AgentHarnesses {
    public static let adapters: [any AgentHarness] = [ClaudeHarness(), CodexHarness()]
    public static let defaultID = "claude"

    public static func named(_ id: String) throws -> any AgentHarness {
        guard let adapter = adapters.first(where: { $0.id == id }) else {
            throw SandboxError("unsupported agent harness: \(id)")
        }
        return adapter
    }
    public static func selected(environment: [String: String]) throws -> any AgentHarness {
        try named(environment["METAL_SANDBOX_HARNESS"] ?? defaultID)
    }
    public static func hookCommand(helper: String, harness: String) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return quote(helper) + " --hook " + quote(harness)
    }
    public static func installResources(at directory: URL, helper: String) throws {
        var names = Set<String>()
        for adapter in adapters {
            for (name, data) in try adapter.resources(helper: helper) {
                guard try ConfinedWorkspace.components(name).count == 1, names.insert(name).inserted else {
                    throw SandboxError("invalid or duplicate harness resource")
                }
                try SafeFiles.writeData(data, to: directory.appendingPathComponent(name))
            }
        }
    }
    public static func environment(resources: URL) -> [String: String] {
        adapters.reduce(into: [:]) { result, adapter in
            result.merge(adapter.environment(resources: resources)) { _, value in value }
        }
    }
}
