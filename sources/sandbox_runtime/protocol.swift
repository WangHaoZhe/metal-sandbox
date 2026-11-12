import Foundation
import SandboxCore

public struct WorkspaceEntry: Codable, Equatable {
    public enum Kind: String, Codable { case directory, file, symlink, other }
    public var name: String
    public var path: String
    public var kind: Kind
    public var size: Int64
    public var modifiedAt: Date
    public var executable: Bool? = nil
}

public struct WorkspaceDirectory: Codable {
    public var path: String
    public var entries: [WorkspaceEntry]
    public var nextAfter: String?
    public init(path: String, entries: [WorkspaceEntry], nextAfter: String? = nil) {
        self.path = path; self.entries = entries; self.nextAfter = nextAfter
    }
}

public struct WorkspaceFile: Codable, Equatable {
    public var path: String
    public var data: Data
    public var executable: Bool
    public var linkTarget: String?
    public init(path: String, data: Data, executable: Bool = false, linkTarget: String? = nil) {
        self.path = path; self.data = data; self.executable = executable; self.linkTarget = linkTarget
    }
    public func validate() throws {
        _ = try ConfinedWorkspace.components(path)
        if let linkTarget {
            // Versioned dylib aliases only: one sibling filename, never a path
            // to a different directory. File APIs still never follow links.
            guard try ConfinedWorkspace.components(linkTarget).count == 1,
                  data.isEmpty, !executable else { throw SandboxError("only sibling file symlinks may be saved") }
        }
    }
}

public struct NativeCommand: Codable {
    public var environment: [String: String]?
    public var argv: [String]
    public var cwd: String
    public var timeoutSeconds: Double
    public var maxLogBytes: Int
    public var deadlineUptimeNanoseconds: UInt64?
    public var agentSession: Bool?
    // A history label, not a correctness verdict or an extra security boundary.
    public var verification: Bool?
    public init(_ argv: [String], cwd: String = ".", timeoutSeconds: Double = 30, maxLogBytes: Int = 1024 * 1024) {
        self.argv = argv; self.cwd = cwd; self.timeoutSeconds = timeoutSeconds; self.maxLogBytes = maxLogBytes
    }
    public func validate() throws {
        if let environment { try EnvironmentVariables.validate(environment) }
        if verification == true {
            guard argv == ["/bin/bash", "./test.sh"], cwd == "tests", agentSession != true else {
                throw SandboxError("verification must run tests/test.sh, not an agent session")
            }
        }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw SandboxError("timeoutSeconds must be a finite positive number")
        }
        guard maxLogBytes >= 1024, maxLogBytes <= 4 * 1024 * 1024 else {
            throw SandboxError("maxLogBytes must be in 1 KiB...4 MiB")
        }
        guard !argv.isEmpty, argv.count <= 256 else { throw SandboxError("command needs 1...256 argv entries") }
        guard argv[0].hasPrefix("/") || argv[0].hasPrefix("./") else {
            throw SandboxError("executable must be absolute or start with ./")
        }
        if argv[0].hasPrefix("./"), argv[0].split(separator: "/").contains("..") {
            throw SandboxError("relative executable must stay inside the workspace")
        }
        guard argv.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 32768 }) else {
            throw SandboxError("invalid command argument")
        }
        guard try JSON.data(self).count <= 128 * 1024 else { throw SandboxError("command is too large") }
        if cwd != "." { _ = try ConfinedWorkspace.components(cwd) }
    }
}

public struct NativeResult: Codable {
    public var leaseID: String
    public var outcome: ProcessOutcome
    public var stdout: Data
    public var stderr: Data
    public var queueWaitSeconds: Double
    public init(leaseID: String, outcome: ProcessOutcome, stdout: Data, stderr: Data, queueWaitSeconds: Double = 0) {
        self.leaseID = leaseID; self.outcome = outcome; self.stdout = stdout; self.stderr = stderr
        self.queueWaitSeconds = queueWaitSeconds
    }
}

public struct HostInfoReply: Codable {
    public var fileOnly: Bool?
    public var protocolVersion = 3
    public var bundleID: String
    public var home: String
    public var temporary: String
    public var workspace: String
    public var bundle: String
    public var pid: Int32
    public var uid: UInt32
    public init(bundleID: String, home: String, temporary: String, workspace: String, bundle: String, pid: Int32, uid: UInt32) {
        self.bundleID = bundleID; self.home = home; self.temporary = temporary; self.workspace = workspace
        self.bundle = bundle; self.pid = pid; self.uid = uid
    }
}

// Private inherited pipe protocol. These messages and lease IDs are not tools
// exposed to the Agent, and candidate processes do not inherit the control FDs.
public struct HostRequest: Codable {
    public var purgeSharedWorkspace: Bool?
    public var result: NativeResult?
    public var environment: [String: String]?
    public enum Operation: String, Codable, CaseIterable {
        case workspaceLocation, trajectory, shellRequests, shellGrant, shellResult, shellRemoteStarted, shellRemoteResult, shellReject, download, upload, info, read, write, listDirectory, validateDirectory, validateExecutable, classifyCommand, export, exec, executionResult, cancel, shutdown, purge, recover

        public var allowedDuringExecution: Bool {
            switch self {
            case .write, .export, .upload, .purge: return false
            case .download: return false // A single-file download is handled separately.
            case .workspaceLocation, .trajectory, .shellRequests, .shellGrant, .shellResult, .shellRemoteStarted, .shellRemoteResult, .shellReject,
                 .info, .read, .listDirectory, .validateDirectory, .validateExecutable, .classifyCommand,
                 .exec, .executionResult, .cancel, .shutdown, .recover: return true
            }
        }
    }
    public var id: String
    public var operation: Operation
    public var path: String?
    public var after: String?
    public var file: WorkspaceFile?
    public var command: NativeCommand?
    public var leaseID: String?
    public var shellID: String?
    public init(_ operation: Operation) { self.operation = operation; id = UUID().uuidString.lowercased() }
}

public struct HostResponse: Codable {
    public var schedulerWaitSeconds: Double?
    public var allowsParallel: Bool?
    public var workspaceLocation: String?
    public var trajectory: TrajectoryReply?
    public var shellInvocations: [ShellInvocation]?
    public var cancelledShellIDs: [String]?
    public var id: String
    public var ok = true
    public var error: String?
    public var info: HostInfoReply?
    public var file: WorkspaceFile?
    public var files: [WorkspaceFile]?
    public var directory: WorkspaceDirectory?
    public var result: NativeResult?
    public init(id: String) { self.id = id }
}
