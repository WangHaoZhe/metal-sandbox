import Foundation
import Darwin
import SandboxCore
import SandboxRuntime

let usage = """
Usage: sandboxctl [--state-dir PATH] COMMAND
  --version       Print release version without contacting a daemon
  doctor          Print local host/Metal metadata (no GPU workload)
  cluster-config FILE  Read and validate a cluster configuration without a service
  cluster-ssh scan|connect  Configure node SSH access using a JSON request on stdin
  sandbox COMMAND Manage App Sandbox instances (sandbox --help)

Trusted local development only.
State: ~/Library/Application Support/MetalSandbox/native
"""
func run() throws -> Int32 {
    if ProcessInfo.processInfo.environment["METAL_SANDBOX_SSH_PASSWORD_PIPE"] != nil { return try ClusterSSH.answerPasswordPrompt() }
    var args = Array(CommandLine.arguments.dropFirst())
    if args == ["--version"] { print(MetalSandboxVersion.current); return 0 }
    var state = NativePaths.state
    if args.first == "--state-dir" {
        args.removeFirst()
        guard !args.isEmpty else { throw SandboxError("missing state directory") }
        state = URL(fileURLWithPath: args.removeFirst(), isDirectory: true).standardizedFileURL
    }
    if args == ["cluster-relay"] {
        guard getuid() != 0 else { throw SandboxError("cluster relay requires a non-root user") }
        let channel = try FramedChannel(input: STDIN_FILENO, output: STDOUT_FILENO)
        while var request = try channel.receive(NativeControlRequest.self, timeout: .infinity) {
            request.operatorToken = request.handle == nil ? try NativeControlClient.operatorToken(stateDirectory: state) : nil
            request.localOnly = true
            try NativeControlClient.relay(request, channel: channel)
        }
        return 0
    }
    if args.isEmpty || args == ["--help"] || args == ["help"] { print(usage); return 0 }
    let command = args.removeFirst()
    switch command {
    case "cluster-ssh": return try ClusterSSH.run(args)
    case "sandbox": return try runNativeCLI(args, state: state)
    case "cluster-config":
        guard args.count == 1 else { throw SandboxError("cluster-config FILE") }
        let configuration = try SafeFiles.read(ClusterConfiguration.self, from: URL(fileURLWithPath: args[0]))
        try configuration.validate()
        print(try JSON.string(configuration)); return 0
    case "doctor":
        guard args.isEmpty else { throw SandboxError("doctor takes no arguments") }
        print(try JSON.string(HostInfo.capture())); return 0
    default: throw SandboxError("unknown command: \(command)\n\(usage)")
    }
}
do { exit(try run()) }
catch {
    FileHandle.standardError.write(Data("sandboxctl: \(error)\n".utf8))
    exit((error as? SandboxError)?.code == .instanceCapacityUnavailable ? EX_TEMPFAIL : 1)
}
