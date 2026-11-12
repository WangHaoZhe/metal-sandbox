import Foundation

// Minimal, tolerant DTOs for the published JSON contract, not backend models.
public struct CLIReply: Decodable {
    public let serviceProcessID: Int32?
    public let cluster: ClusterConfigurationDocument?
    public let verificationSettings: VerificationSettings?
    public let environment: [String: String]?
    public let environmentKeys: [String]?
    public let trajectory: TrajectoryReply?
    public let ok: Bool
    public let error: String?
    public let status: ServiceStatus?
    public let instances: [SandboxInstance]?
    public let instance: SandboxInstance?
    public let execution: ExecutionSummary?
    public let executions: [ExecutionBrief]?
    public let pendingExecutions: [ExecutionBrief]?
    public let nextExecutionCursor: String?
    public let directory: WorkspaceDirectory?
    public let warnings: [String]?
    public let finderRequested: Bool?
}
public struct ServiceStatus: Decodable, Equatable {
    public let schedulingPoolsImplemented: Bool?
    public let acceptedSchedulingPool: String?
    public let crossNodeSchedulingEnabled: Bool?
    public let maxConcurrentInstances: Int?
    public let sharedRoot: String?
    public let clusterImplemented: Bool?
    public let nodeID: String?
    public var clusterNodes: [ClusterNodeStatus]?
    public let automaticVerificationImplemented: Bool?
    public let executionCounts: ExecutionCounts?
    public var isThermallyPaused: Bool { host.thermalState == "critical" }
    public let explicitSnapshotsImplemented: Bool?
    public let taskVerificationImplemented: Bool?
    public let stoppedFileAccessImplemented: Bool?
    public let workspaceRevealImplemented: Bool?
    public let executionHistoryImplemented: Bool?
    public let environmentImplemented: Bool?
    public let trajectoryImplemented: Bool?
    public let startExistingImplemented: Bool?
    public let perInstanceTaskPolicyImplemented: Bool?
    public let taskPolicy: TaskPolicyDocument?
    public let networkClientImplemented: Bool?
    public let containerShellDeletionImplemented: Bool?
    public let directoryListingImplemented: Bool?
    public let permanentDeletionImplemented: Bool?
    public let serviceVersion: String
    public let protocolVersion: Int
    public let activeInstances: Int
    public let pendingExecutions: Int
    public let executionSlots: Int
    public let recoveryReason: String?
    public var host: MachineInfo
    public let appSandboxBackend: Bool
}
public struct MachineInfo: Decodable, Equatable {
    public let modelIdentifier: String
    public let productName: String?
    public let cpu: String
    public let osVersion: String
    public let memoryBytes: UInt64
    public let metalDevice: String?
    public let thermalState: String
    public var utilization: HostUtilization?
}
public struct HostUtilization: Decodable, Equatable {
    public let cpuPercent: Double?
    public let gpuPercent: Double?
    public let memoryUsedBytes: UInt64?
    public let memoryTotalBytes: UInt64?
    public let storageUsedBytes: UInt64?
    public let storageTotalBytes: UInt64?
}
public struct SandboxInstance: Decodable, Identifiable, Hashable {
    public let nodeID: String?
    public let dynamicScheduling: Bool?
    public let executionCounts: ExecutionCounts?
    public let availableActions: Set<String>?
    public let name: String?
    public var sidebarTitle: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? String(id.prefix(12)) }
    public let pendingExecutions: Int?
    public let taskPolicy: TaskPolicyDocument?
    public let networkClient: Bool?
    public let id: String
    public let state: String
    public let createdAt: Double
    public let revisions: Int
    public let checkpointFiles: Int?
    public let checkpointBytes: Int?
    public let checkpointError: String?
    public let error: String?
    public let physical: PhysicalInfo?
    public let ownedBundleIDs: [String]?
    public var isActive: Bool { state == "active" }
    public var hasWorkspace: Bool { availableActions?.contains("files") == true }
    public var canStop: Bool { availableActions?.contains("stop") == true }
    public var canDelete: Bool { availableActions?.contains("delete") == true }
    public var canRestore: Bool { availableActions?.contains("restore") == true }
    public var canStart: Bool { availableActions?.contains("start") == true }
    public var displayState: String {
        ["starting":ui("正在创建", "Creating"), "active":ui("可用", "Active"), "publishing":ui("发布中", "Publishing"), "stopped":ui("已停止", "Stopped"), "stopping":ui("正在停止", "Stopping"), "interrupted":ui("已中断", "Interrupted"), "failed":ui("失败", "Failed"), "cleanup-failed":ui("清理异常", "Cleanup failed"), "deleting":ui("删除未完成", "Deleting"), "delete-failed":ui("删除失败", "Deletion failed")][state] ?? state
    }
}

public struct ClusterNodeStatus: Decodable, Equatable, Identifiable {
    public let id: String
    public let schedulingPool: String?
    public let crossNodeSchedulingEnabled: Bool?
    public var pool: String { schedulingPool ?? "default" }
    public var schedulingNote: String? {
        if crossNodeSchedulingEnabled == false || status?.crossNodeSchedulingEnabled == false { return ui("跨节点调度已关闭", "Cross-node scheduling disabled") }
        guard let status else { return nil }
        if status.schedulingPoolsImplemented != true { return ui("需要更新节点服务", "Node service update required") }
        if let accepted = status.acceptedSchedulingPool, accepted != pool { return ui("调度池配置不匹配", "Scheduling pool mismatch") }
        return nil
    }
    public var status: ServiceStatus?
    public var lastKnownStatus: ServiceStatus?
    public let error: String?
}
public struct ClusterConfigurationDocument: Codable, Equatable {
    public var localNodeID: String
    public var sharedRoot: String?
    public var nodes: [ClusterNodeConfiguration]
    public var maxConcurrentInstances: Int?
    public var schedulingPool: String?
    public var crossNodeSchedulingEnabled: Bool?
    public init(localNodeID: String, sharedRoot: String? = nil, nodes: [ClusterNodeConfiguration] = [], maxConcurrentInstances: Int? = nil) {
        self.localNodeID = localNodeID; self.sharedRoot = sharedRoot; self.nodes = nodes
        self.maxConcurrentInstances = maxConcurrentInstances
    }
}
public struct ClusterNodeConfiguration: Codable, Equatable {
    public var id: String
    public var sshDestination: String
    public var cliPath: String
    public var stateDirectory: String
    public var maxConcurrentInstances: Int?
    public var schedulingPool: String?
    public var crossNodeSchedulingEnabled: Bool?
    public var sshPort: Int?
    public var identityFile: String?
    public var knownHostsFile: String?
    public var hostKeyAlias: String?
    public init(id: String = "", sshDestination: String = "", cliPath: String = "/Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl", stateDirectory: String = "", maxConcurrentInstances: Int? = nil) {
        self.id = id; self.sshDestination = sshDestination; self.cliPath = cliPath; self.stateDirectory = stateDirectory
        self.maxConcurrentInstances = maxConcurrentInstances
    }
}
public struct ClusterSSHRequest: Encodable {
    public var host: String
    public var user: String
    public var port: Int
    public var node: ClusterNodeConfiguration
    public var hostKeys: String?
    public var password: String?
    public init(host: String, user: String, port: Int, node: ClusterNodeConfiguration, hostKeys: String? = nil, password: String? = nil) {
        self.host = host; self.user = user; self.port = port; self.node = node; self.hostKeys = hostKeys; self.password = password
    }
}
public struct ClusterSSHScan: Decodable {
    public let hostKeys: String
    public let fingerprint: String
}
public struct ClusterSSHConnection: Decodable {
    public let node: ClusterNodeConfiguration
    public let status: ServiceStatus
}
public struct ExecutionCounts: Decodable, Hashable {
    public let parallelRunning: Int
    public let parallelWaiting: Int
    public let serialRunning: Int
    public let serialWaiting: Int
}
public struct PhysicalInfo: Decodable, Hashable {
    public let bundleID: String?
    public let pid: Int32
    public let workspace: String
    public let home: String
    public let bundle: String
}
public extension Collection where Element == SandboxInstance {
    var containerBundleIDs: [String] {
        Array(Set(compactMap { $0.physical?.bundleID })).sorted()
    }
}
public struct ExecutionBrief: Decodable, Equatable {
    public var automaticVerification: AutomaticVerification?
    public let verification: Bool?
    public let id: String
    public let instanceID: String
    public var state: String
    public let createdAt: Double
    public let program: String
    public let scheduling: String?
}
public struct ExecutionSummary: Decodable, Equatable {
    public let automaticVerification: AutomaticVerification?
    public let agentExecutionID: String?
    public let testPackageSHA256: String?
    public let metricsSaved: Bool?
    public let id: String
    public let state: String
    public let instanceID: String?
    public let command: ExecutionCommand?
    public let result: ExecutionResult?
    public let error: String?
}
public struct ExecutionCommand: Decodable, Equatable {
    public let verification: Bool?
    public let argv: [String]
    public let cwd: String
    public let timeoutSeconds: Double
    public let agentSession: Bool?
}
public struct ExecutionResult: Decodable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let outcome: ExecutionOutcome
}
public struct ExecutionOutcome: Decodable, Equatable { public let exitCode: Int32?; public let reason: String }

public enum CommandInput {
    public static func display(_ arguments: [String]) -> String {
        arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}
