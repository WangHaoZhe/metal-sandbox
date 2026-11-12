import Foundation
import Darwin

public struct CLIError: LocalizedError {
    public let message: String
    public let reportedFailure: Bool
    public init(_ message: String, reportedFailure: Bool = false) {
        self.message = message; self.reportedFailure = reportedFailure
    }
    public var errorDescription: String? { message }
}

public enum CLITool: String { case sandbox = "sandboxctl", service = "metal-sandboxd" }

public struct CLIConfiguration: Equatable {
    public var clusterConfig: String?
    public var directory: URL
    public var stateDirectory: String
    public var maxConcurrentInstances: Int?
    public init(directory: URL, stateDirectory: String, clusterConfig: String? = nil, maxConcurrentInstances: Int? = nil) {
        self.directory = directory; self.stateDirectory = stateDirectory; self.clusterConfig = clusterConfig; self.maxConcurrentInstances = maxConcurrentInstances
    }
    public func sandbox(_ arguments: [String]) -> [String] { ["--state-dir", stateDirectory, "sandbox"] + arguments }
    public var serviceArguments: [String] {
        ["--allow-trusted-code", "--state-dir", stateDirectory, "--bin-dir", directory.path]
            + (clusterConfig.map { ["--cluster-config", $0] } ?? [])
            + (clusterConfig == nil ? maxConcurrentInstances.map { ["--max-instances", String($0)] } ?? [] : [])
    }
    public var processEnvironment: [String: String] {
        var values = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
        if let directory = ProcessInfo.processInfo.environment["METAL_SANDBOX_COORDINATION_DIR"] {
            values["METAL_SANDBOX_COORDINATION_DIR"] = directory
        }
        return values
    }
}

public struct CLIOutput {
    public let code: Int32
    public let stdout: Data
    public let stderr: Data
    public var text: String { String(decoding: stdout, as: UTF8.self) }
    public var errorText: String { String(decoding: stderr, as: UTF8.self) }
    public func checked() throws -> CLIOutput {
        guard code == 0 else { throw CLIError(errorText.isEmpty ? ui("命令失败（退出码 \(code)）", "Command failed (exit code \(code))") : errorText, reportedFailure: true) }
        return self
    }
    public func reply() throws -> CLIReply {
        _ = try checked()
        let result = try JSONDecoder().decode(CLIReply.self, from: stdout)
        guard result.ok else { throw CLIError(result.error ?? ui("服务拒绝了请求", "The service rejected the request"), reportedFailure: true) }
        return result
    }
}

/// This transport knows only process arguments and public CLI output. It never
/// opens the backend socket, credentials, state database or container paths.
public struct CLIClient {
    public let configuration: CLIConfiguration
    public init(_ configuration: CLIConfiguration) { self.configuration = configuration }

    public func run(_ tool: CLITool = .sandbox, _ arguments: [String], timeout: Double = 180, input: Data? = nil) async throws -> CLIOutput {
        let executable = configuration.directory.appendingPathComponent(tool.rawValue)
        let environment = configuration.processEnvironment
        guard arguments.allSatisfy({ !$0.contains("\0") }), timeout.isFinite, timeout > 0, (input?.count ?? 0) <= 65536 else { throw CLIError(ui("无效命令参数", "Invalid command arguments")) }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("metal_sandbox_ui_" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: scratch) }
                    let outURL = scratch.appendingPathComponent("stdout"), errURL = scratch.appendingPathComponent("stderr")
                    for url in [outURL, errURL] {
                        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CLIError(ui("无法创建前端临时输出文件", "Cannot create a temporary frontend output file")) }
                    }
                    let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
                    defer { try? out.close(); try? err.close() }
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    let pipe = Pipe()
                    process.standardInput = input == nil ? FileHandle.nullDevice : pipe.fileHandleForReading
                    _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    process.standardOutput = out; process.standardError = err
                    process.environment = environment
                    let done = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in done.signal() }
                    try process.run()
                    defer {
                        if process.isRunning {
                            process.terminate()
                            if done.wait(timeout: .now() + 2) == .timedOut, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                            process.waitUntilExit()
                        }
                    }
                    try pipe.fileHandleForReading.close()
                    if let input { try pipe.fileHandleForWriting.write(contentsOf: input) }
                    try pipe.fileHandleForWriting.close()
                    let deadline: DispatchTime = timeout < Double(Int64.max) / 1e9 ? .now() + timeout : .distantFuture
                    if done.wait(timeout: deadline) == .timedOut {
                        // Stop only our CLI observer, never a candidate or the daemon.
                        // A lost response must NOT cause a mutation to be retried.
                        if process.isRunning { process.terminate() }
                        if done.wait(timeout: .now() + 2) == .timedOut, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                        throw CLIError(ui("CLI 等待超时，操作结果未知。请刷新检查；不会自动重试或取消后端任务。", "CLI wait timed out; the operation's result is unknown. Refresh to check. Backend tasks are not automatically retried or cancelled."))
                    }
                    func read(_ url: URL) throws -> Data {
                        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                        let bytes = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
                        guard bytes.count <= 16 * 1024 * 1024 else { throw CLIError(ui("CLI 输出超过前端 16 MiB 读取上限", "CLI output exceeds the frontend's 16 MiB read limit")) }
                        return bytes
                    }
                    continuation.resume(returning: try CLIOutput(code: process.terminationStatus, stdout: read(outURL), stderr: read(errURL)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // The CLI owns execution deadlines and long maintenance operations. A view
    // may bound a read explicitly, but must not guess a second mutation timeout.
    public func sandbox(_ arguments: [String], timeout: Double = .greatestFiniteMagnitude) async throws -> CLIOutput {
        try await run(.sandbox, configuration.sandbox(arguments), timeout: timeout)
    }

    public func readClusterConfiguration(at path: String) async throws -> ClusterConfigurationDocument {
        let output = try await run(.sandbox, ["cluster-config", path], timeout: 10).checked()
        return try JSONDecoder().decode(ClusterConfigurationDocument.self, from: output.stdout)
    }

    public func scanClusterSSH(_ request: ClusterSSHRequest) async throws -> ClusterSSHScan {
        let output = try await run(.sandbox, ["cluster-ssh", "scan"], timeout: 40, input: JSONEncoder().encode(request)).checked()
        return try JSONDecoder().decode(ClusterSSHScan.self, from: output.stdout)
    }

    public func connectClusterSSH(_ request: ClusterSSHRequest) async throws -> ClusterSSHConnection {
        let output = try await run(.sandbox, ["cluster-ssh", "connect"], timeout: 150, input: JSONEncoder().encode(request)).checked()
        return try JSONDecoder().decode(ClusterSSHConnection.self, from: output.stdout)
    }

    public func saveClusterConfiguration(_ document: ClusterConfigurationDocument, at path: String) async throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw CLIError(ui("配置文件需要使用绝对路径。", "Use an absolute path for the configuration file.")) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cluster_configuration_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let draft = temporary.appendingPathComponent("cluster.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: draft, options: .atomic)
        let validated = try await readClusterConfiguration(at: draft.path)
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(validated).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public func enter(_ id: String, onEvent: @escaping (CLIConsoleEvent) -> Void) throws -> CLIConsole {
        try CLIConsole(configuration: configuration, id: id, onEvent: onEvent)
    }

    /// A private, one-shot Terminal document. Its only sandbox operation is the
    /// public CLI, with the same connection settings as the embedded console.
    public func terminalLauncher(_ id: String) throws -> URL {
        let executable = configuration.directory.appendingPathComponent(CLITool.sandbox.rawValue)
        let argv = [executable.path] + configuration.sandbox(["enter", id])
        guard argv.allSatisfy({ !$0.contains("\0") }), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CLIError(ui("sandboxctl 不存在、不可执行或参数无效，请检查连接设置。", "sandboxctl is missing, not executable, or has invalid arguments. Check the connection settings."))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("metal_sandbox_terminal_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("Metal Sandbox.command")
        do {
            let script = "#!/bin/sh\n/bin/rm -f -- " + CommandInput.display([file.path])
                + "\n/bin/rmdir -- " + CommandInput.display([directory.path])
                + "\nexec " + CommandInput.display(argv) + "\n"
            guard FileManager.default.createFile(atPath: file.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else {
                throw CLIError(ui("无法创建终端启动文件。", "Cannot create the Terminal launch file."))
            }
            return file
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    public func submit(id: String, argv: [String], cwd: String, timeout: Double, session: Bool = false) async throws -> String {
        guard !argv.isEmpty, !argv[0].isEmpty, timeout.isFinite, timeout > 0 else { throw CLIError(ui("请填写程序；超时必须是正数秒数", "Enter a program and a positive timeout in seconds")) }
        let reply = try await sandbox(["exec", id, "--cwd", cwd, "--timeout", String(timeout), "--detach"] + (session ? ["--session"] : []) + ["--"] + argv).reply()
        guard let id = reply.execution?.id else { throw CLIError(ui("CLI 没有返回执行 ID；请勿重复提交", "The CLI did not return an execution ID; do not submit again")) }
        return id
    }

    /// Start the existing daemon executable. Closing the UI does not terminate
    /// this process. The service itself owns all instance and GPU lifetimes.
    public func startService(log: URL) throws -> Process {
        let process = Process()
        process.executableURL = configuration.directory.appendingPathComponent(CLITool.service.rawValue)
        process.arguments = configuration.serviceArguments
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CLIError(ui("无法创建服务启动日志", "Cannot create the service startup log")) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle; process.standardError = handle
        process.environment = configuration.processEnvironment
        try process.run()
        return process
    }
}

public enum CLIConsoleEvent {
    case output(Data)
    case error(String)
    case exited(Int32)
}

/// Long-lived public `sandboxctl sandbox enter` process, not a host shell or
/// a candidate PTY. Only this adapter owns its stdin/stdout pipes and process.
public final class CLIConsole {
    private let process: Process
    private let input: FileHandle
    private let writer = DispatchQueue(label: "metal-sandbox-ui.console-input")
    private let lock = NSLock()
    private var closed = false
    private var pendingWrites = 0
    private let onEvent: (CLIConsoleEvent) -> Void

    fileprivate init(configuration: CLIConfiguration, id: String, onEvent: @escaping (CLIConsoleEvent) -> Void) throws {
        guard !id.isEmpty, !id.contains("\0") else { throw CLIError(ui("无效 Sandbox ID", "Invalid sandbox ID")) }
        self.onEvent = onEvent
        process = Process()
        let stdin = Pipe(), stdout = Pipe()
        input = stdin.fileHandleForWriting
        // Suppress SIGPIPE for this owned pipe only, without changing the app's
        // global signal policy when a CLI exits before a queued write.
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw CLIError(ui("无法配置控制台输入管道", "Cannot configure the console input pipe")) }
        process.executableURL = configuration.directory.appendingPathComponent(CLITool.sandbox.rawValue)
        process.arguments = configuration.sandbox(["enter", id])
        process.environment = configuration.processEnvironment
        process.standardInput = stdin
        process.standardOutput = stdout; process.standardError = stdout
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do { try process.run() }
        catch {
            try? input.close(); try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
            throw error
        }
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        let process = process, output = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Foundation read(upToCount:) may wait to fill the buffer on a pipe.
            // One POSIX read delivers currently available bytes immediately.
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let count = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count < 0 { onEvent(.error(ui("控制台输出读取失败：\(String(cString: strerror(errno)))", "Cannot read console output: \(String(cString: strerror(errno)))"))); break }
                if count == 0 { break }
                onEvent(.output(Data(buffer.prefix(count))))
            }
            try? output.close()
            terminated.wait()
            self?.close()
            onEvent(.exited(process.terminationStatus))
        }
    }

    public func send(_ line: String) throws {
        guard !line.isEmpty, !line.contains("\0"), !line.contains("\n"), !line.contains("\r"), line.utf8.count <= 8192 else {
            throw CLIError(ui("一次发送一行命令（最多 8 KiB）；多行内容请保存为脚本后运行。", "Send one command line at a time (up to 8 KiB); save multiple lines as a script to run them."))
        }
        try writeLine(line)
    }

    public func send(_ command: ConsoleCommand) throws {
        try writeLine(command.wireLine())
    }

    private func writeLine(_ line: String) throws {
        lock.lock()
        guard !closed, process.isRunning, pendingWrites < 16 else {
            lock.unlock(); throw CLIError(ui("控制台未连接或输入队列已满。", "The console is disconnected or its input queue is full."))
        }
        pendingWrites += 1; lock.unlock()
        writer.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.pendingWrites -= 1; self.lock.unlock() }
            self.lock.lock(); let closed = self.closed; self.lock.unlock()
            guard !closed else { return }
            do { try self.input.write(contentsOf: Data((line + "\n").utf8)) }
            catch { self.onEvent(.error(ui("控制台输入发送失败，结果未知：\(error.localizedDescription)", "Cannot send console input; result unknown: \(error.localizedDescription)"))); self.close() }
        }
    }

    /// Stop only our CLI observer. Never signal a sandbox process or issue
    /// cancel/stop; a command already submitted to the backend may continue.
    public func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true; lock.unlock()
        if process.isRunning { process.terminate() }
        let input = input
        writer.async { try? input.close() }
    }
    deinit { close() }
}
