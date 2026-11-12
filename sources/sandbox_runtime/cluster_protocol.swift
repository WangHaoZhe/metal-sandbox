import Foundation
import Darwin
import SandboxCore

public struct ClusterNode: Codable, Equatable, Identifiable {
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
    public init(id: String, sshDestination: String, cliPath: String, stateDirectory: String, maxConcurrentInstances: Int? = nil) {
        self.id = id; self.sshDestination = sshDestination
        self.cliPath = cliPath; self.stateDirectory = stateDirectory
        self.maxConcurrentInstances = maxConcurrentInstances
    }
    public func validate() throws {
        try ClusterConfiguration.validateID(id)
        try ClusterConfiguration.validateInstanceLimit(maxConcurrentInstances)
        try ClusterConfiguration.validatePool(schedulingPool)
        if let sshPort, !(1...65535).contains(sshPort) { throw SandboxError("invalid SSH port") }
        if let identityFile { try ClusterConfiguration.validatePath(identityFile) }
        if let knownHostsFile { try ClusterConfiguration.validatePath(knownHostsFile) }
        if let hostKeyAlias {
            guard !hostKeyAlias.isEmpty, hostKeyAlias.count <= 512,
                  hostKeyAlias.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:-[]".contains($0)) }) else {
                throw SandboxError("invalid SSH host key alias")
            }
        }
        guard !sshDestination.isEmpty, !sshDestination.hasPrefix("-"),
              sshDestination.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "@._:-".contains($0)) }) else {
            throw SandboxError("invalid SSH destination; use a hostname or user@hostname")
        }
        try ClusterConfiguration.validatePath(cliPath)
        try ClusterConfiguration.validatePath(stateDirectory)
    }
}

public struct ClusterConfiguration: Codable, Equatable {
    public var localNodeID: String
    public var sharedRoot: String?
    public var nodes: [ClusterNode]
    public var maxConcurrentInstances: Int?
    public var schedulingPool: String?
    public var crossNodeSchedulingEnabled: Bool?
    public init(localNodeID: String, sharedRoot: String? = nil, nodes: [ClusterNode], maxConcurrentInstances: Int? = nil) {
        self.localNodeID = localNodeID; self.sharedRoot = sharedRoot; self.nodes = nodes
        self.maxConcurrentInstances = maxConcurrentInstances
    }
    public func validate() throws {
        try Self.validateID(localNodeID)
        try Self.validateInstanceLimit(maxConcurrentInstances)
        try Self.validatePool(schedulingPool)
        if let sharedRoot { try Self.validatePath(sharedRoot) }
        guard Set(nodes.map(\.id)).count == nodes.count, !nodes.contains(where: { $0.id == localNodeID }) else {
            throw SandboxError("cluster node IDs must be unique")
        }
        for node in nodes { try node.validate() }
    }
    public func pool(for id: String) -> String? {
        if id == localNodeID { return schedulingPool ?? "default" }
        guard let node = nodes.first(where: { $0.id == id }) else { return nil }
        return node.schedulingPool ?? "default"
    }
    public func permitsCrossNodeScheduling(_ id: String) -> Bool {
        if id == localNodeID { return crossNodeSchedulingEnabled != false }
        return nodes.first { $0.id == id }.map { $0.crossNodeSchedulingEnabled != false } ?? false
    }
    public func permitsDispatch(from source: String, to target: String) -> Bool {
        guard let sourcePool = pool(for: source), let targetPool = pool(for: target) else { return false }
        return source == target || (sourcePool == targetPool && permitsCrossNodeScheduling(source) && permitsCrossNodeScheduling(target))
    }
    public static func validatePool(_ pool: String?) throws {
        guard let pool else { return }
        guard !pool.isEmpty, pool.count <= 64, pool == pool.trimmingCharacters(in: .whitespacesAndNewlines),
              pool.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw SandboxError("scheduling pool must contain 1...64 characters without leading/trailing whitespace or control characters")
        }
    }
    public static func validateInstanceLimit(_ limit: Int?) throws {
        if let limit, limit < 0 { throw SandboxError("maximum concurrent instances must be nonnegative") }
    }
    public static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }) else {
            throw SandboxError("node ID must contain 1...64 ASCII letters, digits, underscores or hyphens")
        }
    }
    public static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), path != "/", !path.contains("\0"), !path.contains("\n"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { throw SandboxError("cluster paths must be absolute and normalized") }
    }
}

public struct ClusterNodeStatus: Codable {
    public var id: String
    public var schedulingPool: String?
    public var crossNodeSchedulingEnabled: Bool?
    public var status: NativeServiceStatus?
    public var lastKnownStatus: NativeServiceStatus?
    public var error: String?
    public var sampledAt: Date
    public init(id: String, status: NativeServiceStatus? = nil, error: String? = nil) {
        self.id = id; self.status = status; self.error = error; sampledAt = Date()
    }
    public var available: Bool {
        readyForExecution && (status?.activeInstances ?? instanceLimit) < instanceLimit
    }
    public var instanceLimit: Int { status?.maxConcurrentInstances ?? 32 }
    public var pool: String { schedulingPool ?? "default" }
    public var permitsCrossNodeScheduling: Bool {
        crossNodeSchedulingEnabled != false && status?.schedulingPoolsImplemented == true
            && status?.clusterEnvironmentImplemented == true
            && status?.crossNodeSchedulingEnabled != false
            && (status?.acceptedSchedulingPool == nil || status?.acceptedSchedulingPool == pool)
    }
    public var readyForExecution: Bool {
        status.map { $0.clusterImplemented == true && $0.serviceVersion == MetalSandboxVersion.current
            && $0.recoveryReason == nil && $0.host.thermalState != "critical" } ?? false
    }
}

public struct SharedWorkspace: Codable, Equatable {
    public let root: String
    public let instanceID: String
    public let identity: String
    public let storageNodeID: String?
    public var storageRoot: URL {
        let base = URL(fileURLWithPath: root)
        return storageNodeID.map { base.appendingPathComponent($0) } ?? base
    }
    public var directory: URL { storageRoot.appendingPathComponent(instanceID) }
    public var workspace: URL { directory.appendingPathComponent("workspace") }
    public var home: URL { directory.appendingPathComponent("home") }
    public init(root: String, instanceID: String, identity: String = UUID().uuidString.lowercased(), storageNodeID: String? = nil) throws {
        try ClusterConfiguration.validatePath(root)
        if let storageNodeID { try ClusterConfiguration.validateID(storageNodeID) }
        guard instanceID.hasPrefix("sbx-"), UUID(uuidString: String(instanceID.dropFirst(4))) != nil else { throw SandboxError("invalid shared workspace identity") }
        guard UUID(uuidString: identity) != nil else { throw SandboxError("invalid shared workspace identity token") }
        self.root = root; self.instanceID = instanceID; self.identity = identity
        self.storageNodeID = storageNodeID
    }
    public func validate(root expected: String?) throws {
        guard root == expected else { throw SandboxError("shared workspace root is not configured on this node") }
        _ = try SharedWorkspace(root: root, instanceID: instanceID, identity: identity, storageNodeID: storageNodeID)
    }
    public func prepare() throws {
        let rootURL = URL(fileURLWithPath: root)
        let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              rootURL.resolvingSymlinksInPath().path == root else { throw SandboxError("shared root must be an existing real directory") }
        if storageNodeID != nil {
            let location = FileManager.default.fileExists(atPath: storageRoot.path) ? storageRoot : rootURL
            let storageValues = try location.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard storageValues.isDirectory == true, storageValues.isSymbolicLink != true,
                  location.resolvingSymlinksInPath().path == location.path else {
                throw SandboxError("node storage must be a real directory")
            }
            var filesystem = statfs()
            guard statfs(location.path, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
                throw SandboxError("new shared workspaces must be stored on the owning node's local filesystem")
            }
            try SafeFiles.secureDirectory(storageRoot)
        }
        for url in [directory, workspace, home] { try SafeFiles.secureDirectory(url) }
        let marker = directory.appendingPathComponent("identity.json")
        if FileManager.default.fileExists(atPath: marker.path) { try verify() }
        else { try SafeFiles.write(self, to: marker) }
    }
    public func verify() throws {
        for url in [URL(fileURLWithPath: root), storageRoot, directory, workspace, home] {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true, url.resolvingSymlinksInPath().path == url.path else {
                throw SandboxError("shared workspace directory missing, linked or unmounted")
            }
        }
        guard try SafeFiles.read(SharedWorkspace.self, from: directory.appendingPathComponent("identity.json")) == self else {
            throw SandboxError("shared workspace identity differs; verify that both nodes access the same shared directory")
        }
    }
}

public struct ClusterTask: Codable {
    public var sourceEnvironment: ClusterEnvironment?
    public var loopbackForwardIDs: [String]?
    public var id: String
    public var schedulingPool: String? = "default"
    public var instanceID: String
    public var workspace: SharedWorkspace
    public var command: NativeCommand
    public var environment: [String: String]
    public var networkClient: Bool
    public var taskPolicy: TaskPolicy
    public init(instanceID: String, workspace: SharedWorkspace, command: NativeCommand,
                environment: [String: String], networkClient: Bool, taskPolicy: TaskPolicy) {
        id = UUID().uuidString.lowercased(); self.instanceID = instanceID; self.workspace = workspace
        self.command = command; self.environment = environment; self.networkClient = networkClient; self.taskPolicy = taskPolicy
    }
}

public struct LoopbackForwardInfo: Codable {
    public var id: String
    public var instanceID: String
    public var port: Int
    public var ownerNodeID: String
    public var readyNodeIDs: [String]
    public var expiresAt: Date
    public var nodeErrors: [String: String]
    public init(id: String, instanceID: String, port: Int, ownerNodeID: String,
                readyNodeIDs: [String], expiresAt: Date, nodeErrors: [String: String] = [:]) {
        self.id = id; self.instanceID = instanceID; self.port = port; self.ownerNodeID = ownerNodeID
        self.readyNodeIDs = readyNodeIDs; self.expiresAt = expiresAt; self.nodeErrors = nodeErrors
    }
}

public struct ClusterReservation: Codable {
    public var id: String
    public var taskID: String
    public var expiresAt: Date
    public init(id: String, taskID: String, expiresAt: Date) { self.id = id; self.taskID = taskID; self.expiresAt = expiresAt }
}

public struct ClusterTaskUpdate: Codable {
    public var cleanupConfirmed: Bool?
    public var reservationID: String?
    public var taskID: String
    public var state: String
    public var result: NativeResult?
    public var error: String?
    public init(taskID: String, state: String, result: NativeResult? = nil, error: String? = nil) {
        self.taskID = taskID; self.state = state; self.result = result; self.error = error
    }
}
