import Foundation
import SandboxCore

public enum NativePaths {
    public static var state: URL { Paths.defaultState.appendingPathComponent("native") }
    public static var socket: URL { Paths.coordination.appendingPathComponent("native.sock") }
}

public struct NativeInstanceRecord: Codable {
    public var loopbackForwardIDs: [String]?
    public var nodeID: String?
    public var dynamicScheduling: Bool?
    public var sharedWorkspace: SharedWorkspace?
    public enum State: String, Codable {
        case starting, active, publishing, stopped, stopping, interrupted, failed, deleting, deleted
        case cleanupFailed = "cleanup-failed", deleteFailed = "delete-failed"
    }
    public enum Action: String, Codable { case start, stop, delete, restore, files }
    // Response-only permissions. Runtime membership distinguishes a failed live
    // Host from a historical failed activation; the UI does not reconstruct it.
    public var availableActions: Set<Action>?
    public var name: String?
    public var taskPolicy: TaskPolicy?
    public var networkClient: Bool?
    public var id: String
    public var state: State
    public var createdAt: Date
    public var updatedAt: Date
    public var physical: HostInfoReply?
    public var revisions: Int
    public var checkpointFiles: Int?
    public var checkpointBytes: Int?
    public var checkpointError: String?
    public var checkpointSHA256: String?
    public var error: String?
    // Complete ownership journal for permanent deletion, written before each
    // physical revision is allocated. Missing ownership fails closed.
    public var ownedBundleIDs: [String]?
    public var cleanupWarnings: [String]?
    // Live response metadata; not a persisted queue or a process count.
    public var pendingExecutions: Int?
    public var executionCounts: ExecutionCounts?
    public init(id: String) {
        self.id = id; state = .starting; createdAt = Date(); updatedAt = createdAt; revisions = 0
    }
    public var hasWorkspace: Bool {
        physical != nil && [.active, .stopped, .interrupted, .failed, .cleanupFailed].contains(state)
    }
    public var canStart: Bool { [.stopped, .interrupted, .failed, .cleanupFailed].contains(state) && physical != nil }
    public var canDelete: Bool { [.stopped, .interrupted, .failed, .deleting, .deleteFailed].contains(state) }
    public var canRestore: Bool { [.stopped, .interrupted, .failed].contains(state) && checkpointError == nil }
    public func actions(isLive: Bool) -> Set<Action> {
        var actions: Set<Action> = isLive ? [.stop] : []
        if hasWorkspace { actions.insert(.files) }
        if !isLive {
            if canStart { actions.insert(.start) }
            if canDelete { actions.insert(.delete) }
            if canRestore { actions.insert(.restore) }
        }
        return actions
    }
    public static func normalizedName(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SandboxError("sandbox name must be a single line without control characters")
        }
        return name.isEmpty ? nil : name
    }
    public static func replicaNames(_ value: String?, count: Int) throws -> [String?] {
        let name = try normalizedName(value)
        return (0..<count).map { index in name.map { count > 1 ? "\($0) (\(index + 1))" : $0 } }
    }
}

public struct NativeExecutionRecord: Codable {
    public var schedulerWaitSeconds: Double?
    public var automaticVerification: AutomaticVerification?
    public var agentExecutionID: String?
    public var testPackageSHA256: String?
    public var metricsSaved: Bool?
    public var id: String
    public var instanceID: String
    public var command: NativeCommand
    public var state: String
    public var createdAt: Date
    public var finishedAt: Date?
    public var startedAt: Date?
    public var result: NativeResult?
    public var error: String?
    public var scheduling: String?
    public init(id: String, instanceID: String, command: NativeCommand, scheduling: String? = nil) {
        self.id = id; self.instanceID = instanceID; self.command = command; state = "queued"; createdAt = Date()
        self.command.environment = nil
        self.scheduling = scheduling
    }
    public var isTerminal: Bool { ["succeeded", "failed", "cancelled", "interrupted"].contains(state) }
}

/// Lightweight history index. Full arguments and output are fetched on demand.
public struct NativeExecutionBrief: Codable {
    public var automaticVerification: AutomaticVerification?
    public var verification: Bool?
    public var id: String
    public var instanceID: String
    public var state: String
    public var createdAt: Date
    public var finishedAt: Date?
    public var scheduling: String?
    public var program: String
    public init(_ record: NativeExecutionRecord) {
        automaticVerification = record.automaticVerification
        verification = record.command.verification
        id = record.id; instanceID = record.instanceID; state = record.state
        createdAt = record.createdAt; finishedAt = record.finishedAt; scheduling = record.scheduling
        program = record.command.argv.first ?? ""
    }
}

public struct NativeServiceStatus: Codable {
    public var clusterEnvironmentImplemented: Bool? = true
    public var loopbackForwardingImplemented: Bool? = true
    public var schedulingPoolsImplemented: Bool? = true
    public var crossNodeSchedulingEnabled: Bool?
    public var acceptedSchedulingPool: String?
    public var instanceCapacityImplemented: Bool? = true
    public var maxConcurrentInstances: Int?
    public var sharedRoot: String?
    public var serialSlotAvailable: Bool?
    public var clusterImplemented: Bool? = true
    public var nodeID: String?
    public var clusterNodes: [ClusterNodeStatus]?
    public var queueTimeoutExclusionImplemented: Bool? = true
    public var commandEnvironmentImplemented: Bool? = true
    public var automaticVerificationImplemented: Bool? = true
    public var explicitSnapshotsImplemented: Bool? = true
    public var taskVerificationImplemented: Bool? = true
    public var workspaceRevealImplemented: Bool? = true
    public var stoppedFileAccessImplemented: Bool? = true
    public var executionHistoryImplemented: Bool? = true
    public var environmentImplemented: Bool? = true
    public var trajectoryImplemented: Bool? = true
    public var streamingWorkspaceImplemented: Bool? = true
    public var startExistingImplemented: Bool? = true
    public var perInstanceTaskPolicyImplemented: Bool? = true
    public var networkClientImplemented: Bool? = true
    public var containerShellDeletionImplemented: Bool? = true
    public var directoryListingImplemented = true
    public var permanentDeletionImplemented = true
    public var protocolVersion = 1
    public var serviceVersion = MetalSandboxVersion.current
    public var mode = "native-app-sandbox; trusted-local-development-only"
    public var appSandboxBackend = true
    public var executionSlots = 1 // Serial lane only; parallel tasks may run alongside it.
    public var taskPolicy: TaskPolicy?
    public var activeInstances: Int
    public var pendingExecutions: Int
    public var executionCounts: ExecutionCounts
    public var recoveryReason: String?
    public var stateDirectory: String
    public var toolchain: InstalledClang
    public var host: HostInfo
    public init(activeInstances: Int, executionCounts: ExecutionCounts, recoveryReason: String?, stateDirectory: String, toolchain: InstalledClang, taskPolicy: TaskPolicy? = nil, maxConcurrentInstances: Int = 32) {
        self.maxConcurrentInstances = maxConcurrentInstances
        self.activeInstances = activeInstances; self.executionCounts = executionCounts
        self.pendingExecutions = executionCounts.total; self.recoveryReason = recoveryReason
        self.stateDirectory = stateDirectory; self.toolchain = toolchain; host = HostInfo.capture()
        self.taskPolicy = taskPolicy
    }
}

public struct NativeControlRequest: Codable {
    public var forwardID: String?
    public var forwardPort: Int?
    public var onlyIfIdle: Bool?
    public var instanceLimit: Int?
    public var nodeID: String?
    public var schedulingPool: String?
    public var dynamicScheduling: Bool?
    public var clusterTask: ClusterTask?
    public var clusterUpdate: ClusterTaskUpdate?
    public var reservationID: String?
    public var localOnly: Bool?
    public var verificationSettings: VerificationSettings?
    public var testPackageSHA256: String?
    public var taskImport: Bool?
    public var verificationTimeout: Double?
    public var responseTimeout: Double {
        switch operation {
        case "port-forward-probe": return 10
        case "create", "start", "stop", "delete", "restore", "snapshot", "export", "cleanup-deleted", "cleanup-unclaimed": return .infinity
        case "status", "list", "inspect", "execution", "executions", "trajectory", "ls", "read", "workspace-location":
            return localOnly == true ? 120 : 1920
        default: return 120
        }
    }
    public var name: String?
    public var environment: [String: String]?
    public var revealEnvironment: Bool?
    public var taskPolicy: TaskPolicy?
    public var networkClient: Bool?
    public var requestID = UUID().uuidString.lowercased()
    public var operation: String
    public var operatorToken: String?
    public var handle: SandboxHandle?
    public var instanceID: String?
    public var executionID: String?
    public var count: Int?
    public var command: NativeCommand?
    public var path: String?
    public var after: String?
    public var file: WorkspaceFile?
    public var files: [WorkspaceFile]?
    public var operations: Set<SandboxOperation>?
    public var confirmed: Bool?
    public var bundleIDs: [String]?
    public var note: String?
    public init(_ operation: String) { self.operation = operation }
}
public struct NativeControlReply: Codable {
    public var portForward: LoopbackForwardInfo?
    public var serviceProcessID: Int32?
    public var confirmed: Bool?
    public var cluster: ClusterConfiguration?
    public var clusterTasks: [ClusterTask]?
    public var clusterUpdate: ClusterTaskUpdate?
    public var clusterReservation: ClusterReservation?
    public var claimed: Bool?
    public var verificationSettings: VerificationSettings?
    public var testPackageSHA256: String?
    public var errorCode: SandboxError.Code?
    public var workspaceLocation: String?
    public var environment: [String: String]?
    public var environmentKeys: [String]?
    public var trajectory: TrajectoryReply?
    public var requestID: String
    public var ok = true
    public var error: String?
    public var status: NativeServiceStatus?
    public var instances: [NativeInstanceRecord]?
    public var instance: NativeInstanceRecord?
    public var handle: SandboxHandle?
    public var execution: NativeExecutionRecord?
    public var executions: [NativeExecutionBrief]?
    public var pendingExecutions: [NativeExecutionBrief]?
    public var nextExecutionCursor: String?
    public var file: WorkspaceFile?
    public var files: [WorkspaceFile]?
    public var directory: WorkspaceDirectory?
    public var warnings: [String]?
    public var cleanup: [NativeCleanupItem]?
    public init(requestID: String) { self.requestID = requestID }
}

public struct NativeCleanupItem: Codable {
    public var bundleID: String
    public var source: String
    public var state: String
    public var error: String?
    public init(bundleID: String, source: String, state: String = "planned", error: String? = nil) {
        self.bundleID = bundleID; self.source = source; self.state = state; self.error = error
    }
}
