import Foundation
import Darwin
import SandboxCore
import SandboxRuntime
import SandboxManagement

func runNativeDaemon(_ arguments: [String]) throws {
    var args = arguments, state = NativePaths.state
    var bin = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
    var trusted = false
    var taskPolicyURL: URL?
    var clusterURL: URL?, sharedRoot: String?
    var maxConcurrentInstances: Int?
    while !args.isEmpty {
        switch args.removeFirst() {
        case "--allow-trusted-code": trusted = true
        case "--state-dir":
            guard !args.isEmpty else { throw SandboxError("missing state directory") }
            state = URL(fileURLWithPath: args.removeFirst()).standardizedFileURL
        case "--bin-dir":
            guard !args.isEmpty else { throw SandboxError("missing runtime binary directory") }
            bin = URL(fileURLWithPath: args.removeFirst()).standardizedFileURL
        case "--task-policy":
            guard !args.isEmpty else { throw SandboxError("missing task policy file") }
            taskPolicyURL = URL(fileURLWithPath: args.removeFirst()).standardizedFileURL
        case "--cluster-config":
            guard !args.isEmpty else { throw SandboxError("missing cluster configuration") }
            clusterURL = URL(fileURLWithPath: args.removeFirst()).standardizedFileURL
        case "--shared-root":
            guard !args.isEmpty else { throw SandboxError("missing shared root") }
            sharedRoot = args.removeFirst()
        case "--max-instances":
            guard !args.isEmpty, let limit = Int(args.removeFirst()), limit >= 0 else { throw SandboxError("--max-instances requires a nonnegative integer") }
            maxConcurrentInstances = limit
        case "--help":
            print("metal-sandboxd --allow-trusted-code [--state-dir PATH] [--bin-dir PATH] [--task-policy FILE] [--cluster-config FILE | --shared-root PATH] [--max-instances N]\nNative App Sandbox for trusted local development.")
            return
        default: throw SandboxError("unknown native manager option")
        }
    }
    guard trusted, getuid() != 0 else { throw SandboxError("native manager requires --allow-trusted-code and a non-root user") }
    guard clusterURL == nil || sharedRoot == nil else { throw SandboxError("use --cluster-config or --shared-root") }
    let manager = try NativeManager(directory: state, binDirectory: bin, taskPolicyURL: taskPolicyURL, clusterURL: clusterURL, sharedRoot: sharedRoot, maxConcurrentInstances: maxConcurrentInstances)
    defer { manager.shutdown() }
    var server: NativeControlServer!
    server = NativeControlServer(transfer: manager.transfer) { request in
        var reply = manager.handle(request)
        reply.serviceProcessID = getpid()
        if request.operation == "shutdown", reply.ok { server.requestStop() }
        return reply
    }
    var signals: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
        source.setEventHandler { manager.beginShutdown(); server.requestStop() }
        source.resume(); signals.append(source)
    }
    defer { signals.forEach { $0.cancel() } }
    try server.serve {
        print("metal-sandboxd native ready: \(NativePaths.socket.path)")
        print("State: \(state.path)\nTRUSTED LOCAL CODE ONLY. App Sandbox active.")
        fflush(stdout)
    }
    withExtendedLifetime(signals) {}
}
