import Foundation
import Darwin
import CryptoKit
import SandboxCore
import SandboxRuntime

enum ClusterSSH {
    struct Request: Decodable {
        var host: String
        var user: String
        var port: Int
        var node: ClusterNode
        var hostKeys: String?
        var password: String?
        func validate() throws {
            guard !host.isEmpty, !host.hasPrefix("-"), host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".:-".contains($0)) }),
                  !user.isEmpty, user != "root", !user.hasPrefix("-"), user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
                  (1...65535).contains(port), node.sshDestination == user + "@" + host else { throw SandboxError("invalid SSH host, username or port") }
            try node.validate()
        }
    }
    struct Scan: Encodable { var hostKeys: String; var fingerprint: String }
    struct Connection: Encodable { var node: ClusterNode; var status: NativeServiceStatus }

    static func run(_ args: [String]) throws -> Int32 {
        guard args.count == 1, ["scan", "connect"].contains(args[0]), getuid() != 0 else { throw SandboxError("cluster-ssh scan|connect requires a non-root user and JSON on stdin") }
        var input = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
            input.append(chunk)
            guard input.count <= 65536 else { throw SandboxError("SSH setup request too large") }
        }
        let request = try JSON.decoder().decode(Request.self, from: input)
        try request.validate()
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        try SafeFiles.secureDirectory(ssh)
        let scratch = ssh.appendingPathComponent("metal_sandbox_setup_" + UUID().uuidString.lowercased())
        try SafeFiles.secureDirectory(scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let runner = Runner(directory: scratch)
        let scanned = scratch.appendingPathComponent("host_keys")
        if args[0] == "scan" {
            let keys = try runner.run(["/usr/bin/ssh-keyscan", "-T", "5", "-p", String(request.port), "-t", "ed25519", request.host])
            guard !keys.isEmpty else { throw SandboxError("SSH host returned no Ed25519 host key") }
            try keys.write(to: scanned)
            let fingerprint = try runner.run(["/usr/bin/ssh-keygen", "-l", "-E", "sha256", "-f", scanned.path])
            print(try JSON.string(Scan(hostKeys: String(decoding: keys, as: UTF8.self), fingerprint: String(decoding: fingerprint, as: UTF8.self))))
            return 0
        }
        guard let keys = request.hostKeys, !keys.isEmpty else { throw SandboxError("confirm the SSH host fingerprint first") }
        try Data(keys.utf8).write(to: scanned)
        _ = try runner.run(["/usr/bin/ssh-keygen", "-l", "-E", "sha256", "-f", scanned.path])
        let endpoint = SHA256.hash(data: Data("\(request.host):\(request.port)".utf8)).map { String(format: "%02x", $0) }.joined()
        let knownHosts = ssh.appendingPathComponent("metal_sandbox_host_" + endpoint)
        if FileManager.default.fileExists(atPath: knownHosts.path) {
            guard try SafeFiles.readRegular(knownHosts, limit: 65536) == Data(keys.utf8) else {
                throw SandboxError("SSH host key changed. Verify the remote host and remove its saved Metal Sandbox host key manually before reconnecting.")
            }
        } else {
            guard FileManager.default.createFile(atPath: knownHosts.path, contents: Data(keys.utf8), attributes: [.posixPermissions: 0o600]) else { throw SandboxError("cannot save SSH host key") }
        }
        let identity = ssh.appendingPathComponent("metal_sandbox_cluster")
        if !FileManager.default.fileExists(atPath: identity.path) {
            _ = try runner.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "metal_sandbox_cluster", "-f", identity.path])
        }
        let publicKey = try runner.run(["/usr/bin/ssh-keygen", "-y", "-P", "", "-f", identity.path])
        var node = request.node
        node.sshPort = request.port; node.identityFile = identity.path; node.knownHostsFile = knownHosts.path
        node.hostKeyAlias = request.port == 22 ? request.host : "[\(request.host)]:\(request.port)"
        let password = request.password ?? ""
        if !password.isEmpty {
            guard !password.contains("\n"), !password.contains("\r"), !password.contains("\0"), password.utf8.count <= 4096 else { throw SandboxError("invalid SSH password") }
            let fifo = scratch.appendingPathComponent("password_pipe")
            guard mkfifo(fifo.path, 0o600) == 0 else { throw SandboxError("cannot create SSH password pipe") }
            let fd = open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw SandboxError("cannot open SSH password pipe") }
            defer { close(fd) }
            let bytes = Data(password.utf8)
            guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count else { throw SandboxError("cannot send SSH password") }
            var env = ProcessInfo.processInfo.environment
            env["SSH_ASKPASS"] = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            env["SSH_ASKPASS_REQUIRE"] = "force"; env["DISPLAY"] = "metal-sandbox"
            env["METAL_SANDBOX_SSH_PASSWORD_PIPE"] = fifo.path
            env["METAL_SANDBOX_SSH_PASSWORD_LENGTH"] = String(bytes.count)
            // OpenSSH takes the first value for each option; password options precede the relay defaults.
            let argv = ["/usr/bin/ssh", "-o", "BatchMode=no", "-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "NumberOfPasswordPrompts=1"]
                + Array(try SSHClusterTransport.connectionArguments(node).dropFirst()) + ["--", node.sshDestination, """
                set -eu
                umask 077
                mkdir -p "$HOME/.ssh"
                chmod 700 "$HOME/.ssh"
                touch "$HOME/.ssh/authorized_keys"
                chmod 600 "$HOME/.ssh/authorized_keys"
                IFS= read -r key
                if ! grep -qxF -- "$key" "$HOME/.ssh/authorized_keys"; then
                    printf '\\n%s\\n' "$key" >> "$HOME/.ssh/authorized_keys"
                fi
                """]
            _ = try runner.run(argv, input: publicKey, environment: env)
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = [node.cliPath, "--state-dir", node.stateDirectory, "sandbox", "status"].map(quote).joined(separator: " ")
        let output = try runner.run(SSHClusterTransport.connectionArguments(node) + ["--", node.sshDestination, command])
        let reply = try JSON.decoder().decode(NativeControlReply.self, from: output)
        guard reply.ok, let status = reply.status else { throw SandboxError(reply.error ?? "remote service did not return status") }
        guard status.clusterImplemented == true, status.serviceVersion == MetalSandboxVersion.current else {
            throw SandboxError("install and start Metal Sandbox \(MetalSandboxVersion.current) on the remote node")
        }
        print(try JSON.string(Connection(node: node, status: status)))
        return 0
    }

    static func answerPasswordPrompt() throws -> Int32 {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["METAL_SANDBOX_SSH_PASSWORD_PIPE"], let value = env["METAL_SANDBOX_SSH_PASSWORD_LENGTH"],
              let count = Int(value), (1...4096).contains(count) else { throw SandboxError("invalid SSH password channel") }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw SandboxError("SSH password channel unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { throw SandboxError("unsafe SSH password channel") }
        var bytes = Data(count: count)
        guard bytes.withUnsafeMutableBytes({ Darwin.read(fd, $0.baseAddress, $0.count) }) == count else { throw SandboxError("SSH password has already been consumed") }
        FileHandle.standardOutput.write(bytes); FileHandle.standardOutput.write(Data([10]))
        return 0
    }

    private struct Runner {
        var directory: URL
        func run(_ argv: [String], input: Data? = nil, environment: [String: String]? = nil) throws -> Data {
            let outURL = directory.appendingPathComponent("stdout"), errURL = directory.appendingPathComponent("stderr")
            for url in [outURL, errURL] {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw SandboxError("cannot create SSH setup output") }
            }
            let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
            defer { try? out.close(); try? err.close() }
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: argv[0]); process.arguments = Array(argv.dropFirst())
            process.standardInput = input == nil ? FileHandle.nullDevice : pipe.fileHandleForReading
            process.standardOutput = out; process.standardError = err; process.environment = environment
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
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
            if done.wait(timeout: .now() + 25) == .timedOut {
                if process.isRunning { process.terminate() }
                if done.wait(timeout: .now() + 2) == .timedOut, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw SandboxError("SSH connection timed out")
            }
            guard process.terminationStatus == 0 else {
                let error = try SafeFiles.readRegular(errURL, limit: 256 * 1024)
                throw SandboxError("\(URL(fileURLWithPath: argv[0]).lastPathComponent) failed: " + String(decoding: error, as: UTF8.self))
            }
            return try SafeFiles.readRegular(outURL, limit: 256 * 1024)
        }
    }
}
