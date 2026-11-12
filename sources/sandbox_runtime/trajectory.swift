import Foundation
import SandboxCore

public struct TrajectorySession: Codable {
    public var id: String
    public var sessionID: String
    public var source: String
    public var harness: String
    public var modifiedAt: Date
    public init(id: String, sessionID: String, source: String, harness: String, modifiedAt: Date) {
        self.id = id; self.sessionID = sessionID; self.source = source; self.harness = harness; self.modifiedAt = modifiedAt
    }
}

public struct TrajectoryPage: Codable {
    public var data: Data
    public var nextAfter: String
    public var reset: Bool
    public var atEnd: Bool
}

public struct TrajectoryReply: Codable {
    public var harness: String?
    public var sessions: [TrajectorySession]?
    public var page: TrajectoryPage?
    public var sessionsTruncated: Bool?
}

/// Runs in Host. Only recognized conversation logs are readable, not arbitrary
/// HOME files (settings, credentials, etc.). Paths are opened without links.
public final class AgentTrajectory {
    private let home: ConfinedWorkspace
    private let adapters: [any AgentHarness]
    public init(home: URL, adapters: [any AgentHarness] = AgentHarnesses.adapters) throws {
        self.home = try ConfinedWorkspace(directory: home); self.adapters = adapters
    }

    private func entries(_ path: String) throws -> [WorkspaceEntry] {
        var result: [WorkspaceEntry] = [], after: String?
        repeat {
            let page = try home.listDirectory(path, after: after)
            result += page.entries; after = page.nextAfter
        } while after != nil
        return result
    }
    public func read(session: String?, after: String?) throws -> TrajectoryReply {
        if let session {
            _ = try ConfinedWorkspace.components(session)
            let matches = adapters.filter { $0.acceptsTrajectory(session) }
            guard matches.count == 1, let adapter = matches.first else { throw SandboxError("not a supported harness trajectory path") }
            return TrajectoryReply(harness: adapter.id, page: try home.readGrowingFile(session, after: after))
        }
        guard after == nil else { throw SandboxError("trajectory cursor requires a session") }
        let found = try adapters.flatMap { try $0.trajectories(entries: entries) }
        let ordered = found.sorted { $0.modifiedAt == $1.modifiedAt ? $0.id < $1.id : $0.modifiedAt > $1.modifiedAt }
        return TrajectoryReply(sessions: Array(ordered.prefix(256)), sessionsTruncated: ordered.count > 256)
    }
}
