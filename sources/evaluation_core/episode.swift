import Foundation
import SandboxCore
import SandboxRuntime

public enum AgentAction {
    case write(WorkspaceFile), read(String), exec(NativeCommand), finish
}
public protocol AgentDriver {
    mutating func next(observation: ToolObservation?) throws -> AgentAction
}
public struct ScriptedAgent: AgentDriver {
    private var actions: [AgentAction]
    private var index = 0
    public init(_ actions: [AgentAction]) { self.actions = actions }
    public mutating func next(observation: ToolObservation?) throws -> AgentAction {
        guard index < actions.count else { return .finish }
        defer { index += 1 }; return actions[index]
    }
}
public struct ToolObservation: Codable {
    public var kind: String
    public var file: WorkspaceFile?
    public var command: NativeCommand?
    public var execution: NativeResult?
    public init(kind: String, file: WorkspaceFile? = nil, command: NativeCommand? = nil, execution: NativeResult? = nil) {
        self.kind = kind; self.file = file; self.command = command; self.execution = execution
    }
}
public struct VerificationResult: Codable {
    public var correctness: Bool
    public var kind: String
    public var execution: NativeResult
    public init(correctness: Bool, kind: String, execution: NativeResult) {
        self.correctness = correctness; self.kind = kind; self.execution = execution
    }
}
public protocol Verifier {
    func verify(in sandbox: SandboxSession) throws -> VerificationResult
}
public struct OutputVerifier: Verifier {
    public let command: NativeCommand
    public let expected: Data
    public init(command: NativeCommand, expected: Data) { self.command = command; self.expected = expected }
    public func verify(in sandbox: SandboxSession) throws -> VerificationResult {
        let result = try sandbox.execute(command)
        return VerificationResult(correctness: result.outcome.reason == .exited && result.outcome.exitCode == 0 && result.stdout == expected,
                                  kind: "sample-output-check", execution: result)
    }
}
public struct EpisodeReport: Codable {
    public var id: String
    public var state: String
    public var turns: Int
    public var artifactID: String?
    public var verification: VerificationResult?
    public var error: String?
    public var wallSeconds: Double
}
private struct TraceEvent: Codable {
    var turn: Int
    var timestamp: Date
    var event: String
    var observation: ToolObservation?
}

private final class BudgetedSession: SandboxSession {
    let base: SandboxSession
    let deadline: UInt64
    var id: String { base.id }
    init(_ base: SandboxSession, deadline: UInt64) { self.base = base; self.deadline = deadline }
    func remaining() throws -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now + 100_000_000 < deadline else { throw SandboxError("episode deadline exhausted") }
        return Double(deadline - now) / 1e9
    }
    func read(_ path: String) throws -> WorkspaceFile { _ = try remaining(); return try base.read(path) }
    func listDirectory(_ path: String, after: String?) throws -> WorkspaceDirectory {
        _ = try remaining(); return try base.listDirectory(path, after: after)
    }
    func write(_ file: WorkspaceFile) throws { _ = try remaining(); try base.write(file) }
    func export() throws -> [WorkspaceFile] { _ = try remaining(); return try base.export() }
    func execute(_ command: NativeCommand) throws -> NativeResult {
        var bounded = command
        bounded.timeoutSeconds = min(command.timeoutSeconds, try remaining())
        bounded.deadlineUptimeNanoseconds = min(command.deadlineUptimeNanoseconds ?? deadline, deadline)
        return try base.execute(bounded)
    }
    func close() throws { try base.close() }
}

/// Upper layer only: no process spawning, no host paths supplied by the Agent,
/// and no Verifier truth or authority is copied into a candidate container.
public final class EpisodeController {
    private let store: ArtifactStore
    private let directory: URL
    public init(directory: URL, store: ArtifactStore) throws {
        self.directory = directory; self.store = store
        try SafeFiles.secureDirectory(directory)
    }
    public func run<A: AgentDriver>(agent: inout A, working: SandboxSession,
        makeVerifierSandbox: (ArtifactSnapshot) throws -> SandboxSession, verifier: Verifier,
        maxTurns: Int = 64, budgetSeconds: Double = 300) throws -> EpisodeReport {
        guard maxTurns > 0, maxTurns <= 1000, budgetSeconds.isFinite, budgetSeconds > 0, budgetSeconds <= 86400 else {
            throw SandboxError("invalid episode budget")
        }
        let id = UUID().uuidString.lowercased(), start = DispatchTime.now().uptimeNanoseconds
        let deadline = start + UInt64(budgetSeconds * 1e9)
        let boundedWorking = BudgetedSession(working, deadline: deadline)
        let episode = directory.appendingPathComponent(id)
        try SafeFiles.secureDirectory(episode)
        let traceURL = episode.appendingPathComponent("trace.jsonl")
        try SafeFiles.writeData(Data(), to: traceURL)
        let trace = try FileHandle(forWritingTo: traceURL)
        defer { try? trace.close() }
        var traceBytes = 0
        var report = EpisodeReport(id: id, state: "running", turns: 0, wallSeconds: 0)
        let reportURL = episode.appendingPathComponent("episode.json")
        try SafeFiles.write(report, to: reportURL)
        var verificationSandbox: SandboxSession?
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }
        func event(_ name: String, _ observation: ToolObservation? = nil) throws {
            var data = try JSON.data(TraceEvent(turn: report.turns, timestamp: Date(), event: name, observation: observation))
            data.append(10); traceBytes += data.count
            guard traceBytes <= 64 * 1024 * 1024 else { throw SandboxError("episode trace limit exceeded") }
            try trace.write(contentsOf: data)
        }
        func remaining() throws -> Double {
            let result = budgetSeconds - elapsed()
            guard result >= 0.1 else { throw SandboxError("episode wall-clock budget exhausted") }
            return result
        }
        do {
            var last: ToolObservation?
            var finished = false
            while report.turns < maxTurns {
                _ = try remaining()
                let action = try agent.next(observation: last)
                if case .finish = action { finished = true; break }
                report.turns += 1
                switch action {
                case .write(let file):
                    try boundedWorking.write(file)
                    last = ToolObservation(kind: "write", file: file)
                case .read(let path): last = ToolObservation(kind: "read", file: try boundedWorking.read(path))
                case .exec(var command):
                    command.timeoutSeconds = min(command.timeoutSeconds, try remaining())
                    last = ToolObservation(kind: "exec", command: command, execution: try boundedWorking.execute(command))
                case .finish: break
                }
                try event("tool-result", last)
            }
            guard finished else { throw SandboxError("episode turn budget exhausted") }
            _ = try remaining()
            let artifact = try store.freeze(boundedWorking.export())
            report.artifactID = artifact.id
            try event("artifact-frozen")
            // Freeze, stop/revoke development access, then publish the exact
            // stored bytes into a new identity. Never replace a running bundle.
            try working.close()
            try event("working-stopped")
            let fresh = try makeVerifierSandbox(store.load(artifact.id))
            verificationSandbox = fresh
            guard fresh.id != working.id, try fresh.export().isEmpty else { throw SandboxError("Verifier requires a distinct, empty instance") }
            let boundedFresh = BudgetedSession(fresh, deadline: deadline)
            for file in try store.load(artifact.id).files { try boundedFresh.write(file) }
            _ = try remaining()
            report.verification = try verifier.verify(in: boundedFresh)
            _ = try remaining()
            try event("verified", ToolObservation(kind: "verification", execution: report.verification?.execution))
            report.state = report.verification?.correctness == true ? "succeeded" : "incorrect"
        } catch {
            report.state = "failed"; report.error = String(describing: error)
            try? event("failed")
        }
        // Cleanup failures make the task fail.
        for sandbox in [verificationSandbox, working].compactMap({ $0 }) {
            do { try sandbox.close() }
            catch { report.state = "failed"; report.error = "cleanup: \(error)" }
        }
        report.wallSeconds = elapsed()
        try SafeFiles.write(report, to: reportURL)
        return report
    }
}
