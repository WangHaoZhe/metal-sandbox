import Foundation
import Darwin
import SandboxCore
import SandboxRuntime

func executeShell(_ shell: String, _ script: String) throws -> Never {
    var argv = [shell, "-c", script].map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    argv.withUnsafeMutableBufferPointer { _ = execv(shell, $0.baseAddress!) }
    throw SandboxError("cannot execute the configured shell")
}
func run() throws -> Int32 {
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["METAL_SANDBOX_BRIDGE_DIRECTORY"], let helper = environment["METAL_SANDBOX_SHELL_HELPER"] else {
        throw SandboxError("shell bridge must run in a managed sandbox")
    }
    let resources = URL(fileURLWithPath: helper).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    let inputs = URL(fileURLWithPath: directory).appendingPathComponent("shell_inputs")
    var arguments = Array(CommandLine.arguments.dropFirst())
    var startNotification: Int32?
    if arguments.first == "--notify-start" {
        guard arguments.count == 3, let fd = Int32(arguments[1]), fd > STDERR_FILENO,
              fcntl(fd, F_GETFD) >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw SandboxError("invalid start notification descriptor")
        }
        startNotification = fd; arguments.removeFirst(2)
    }
    if arguments.count == 2, arguments[0] == "--hook" {
        let harness = try AgentHarnesses.named(arguments[1])
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let command = try harness.toolCommand(from: data)
        try SafeFiles.secureDirectory(inputs)
        let id = UUID().uuidString.lowercased()
        try SafeFiles.writeData(Data(command.utf8), to: inputs.appendingPathComponent(id))
        let annotated = "# metal-sandbox-tool:\(id)\n" + command
        let invocation = harness.toolInvocation(command: annotated, helper: helper)
        let reply = try harness.toolReply(to: data, command: invocation)
        FileHandle.standardOutput.write(reply); return 0
    }
    let harness = try AgentHarnesses.selected(environment: environment)
    let shell = harness.shell(environment: environment)
    guard shell.hasPrefix("/"), arguments.count == 1 else { throw SandboxError("invalid shell bridge invocation") }
    let argument = arguments[0]
    // A prefix may wrap its own hook. Exempt only this fixed annotation entry,
    // never arbitrary commands or another provider's hook.
    if argument == AgentHarnesses.hookCommand(helper: helper, harness: harness.id) { try executeShell(shell, argument) }
    guard environment["METAL_SANDBOX_AGENT_SESSION"] == "1" else {
        throw SandboxError("harness bridge requires an Agent session (prepare or exec --session), not an outer serial task")
    }
    var raw = argument
    let pattern = "# metal-sandbox-tool:([0-9a-f-]{36})"
    let regex = try NSRegularExpression(pattern: pattern)
    let matches = regex.matches(in: argument, range: NSRange(argument.startIndex..., in: argument))
    if matches.count == 1, let range = Range(matches[0].range(at: 1), in: argument) {
        let id = String(argument[range])
        guard UUID(uuidString: id) != nil else { throw SandboxError("invalid tool annotation") }
        let path = inputs.appendingPathComponent(id)
        raw = String(decoding: try SafeFiles.readRegular(path, limit: 128 * 1024), as: UTF8.self)
        try FileManager.default.removeItem(at: path)
    }
    var argv = shellCommandArguments(raw)
    if argv.isEmpty { try executeShell(shell, argument) }
    if !argv[0].contains("/") {
        argv[0] = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + argv[0] }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/nonexistent/" + argv[0]
    } else if !argv[0].hasPrefix("/") {
        argv[0] = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(argv[0]).standardizedFileURL.path
    }
    let command = NativeCommand(argv, timeoutSeconds: .greatestFiniteMagnitude)
    let policy = try SafeFiles.read(TaskPolicy.self, from: resources.appendingPathComponent("task_policy.json"), limit: 128 * 1024)
    let parallel: Bool
    if policy.mode == .allowlist {
        parallel = policy.allowsParallel(NativeCommand([shell, "-c", raw]),
            shellEnvironment: environment, workingDirectory: FileManager.default.currentDirectoryPath)
    } else { parallel = policy.allowsParallel(command) }
    // Both lanes register their lifetime. Parallel work is granted immediately,
    // without entering the serial FIFO, and is now visible in pending counts.
    return try ShellBridgeClient.run(script: argument, command: command, directory: URL(fileURLWithPath: directory), shell: shell, parallel: parallel, startNotification: startNotification)
}
do { exit(try run()) }
catch {
    FileHandle.standardError.write(Data("sandbox-shell: \(error)\n".utf8))
    exit(CommandLine.arguments.dropFirst().elementsEqual(["--hook", "codex"]) ? 2 : 1)
}
