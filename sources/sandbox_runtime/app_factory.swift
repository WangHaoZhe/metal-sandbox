import Foundation
import CryptoKit
import CoreServices
import Darwin
import SandboxCore

/// A single, frozen executable. The controller chooses it from exported bytes,
/// never by following a candidate-controlled path on the host filesystem.
public struct PublishedCandidate {
    public let source: WorkspaceFile
    public let sourceSHA256: String
    public let signedSHA256: String

    public static func validate(_ file: WorkspaceFile) throws {
        _ = try ConfinedWorkspace.components(file.path)
        guard file.executable, file.data.count >= 32,
              Array(file.data.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe],
              Array(file.data.dropFirst(12).prefix(4)) == [2, 0, 0, 0] else {
            throw SandboxError("publication requires a thin 64-bit Mach-O MH_EXECUTE file")
        }
        // This is only a format precheck; codesign must validate the full image.
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Frozen evaluation entrypoints only. Development executes in place and
    /// does not route shell/CMake nested launches through this publisher.
    public func matches(_ command: NativeCommand) throws -> Bool {
        try command.validate()
        guard let executable = command.argv.first, executable.hasPrefix("./") else { return false }
        let relative = String(executable.dropFirst(2))
        _ = try ConfinedWorkspace.components(relative)
        let path = command.cwd == "." ? relative : command.cwd + "/" + relative
        return path == source.path
    }
}

/// Only fixed Apple control-plane tools use this path. Candidate compilation and
/// execution MUST use AppSandboxSession instead. This is not an Agent tool API.
private enum ControlPlaneTool {
    static func run(_ executable: String, _ arguments: [String], logs: URL) throws -> Data {
        guard ["/usr/bin/codesign", "/usr/bin/xcrun"].contains(executable) else {
            throw SandboxError("unapproved control-plane tool")
        }
        let directory = logs.appendingPathComponent(UUID().uuidString.lowercased())
        try SafeFiles.secureDirectory(directory)
        let stdout = directory.appendingPathComponent("stdout.log")
        let stderr = directory.appendingPathComponent("stderr.log")
        let outcome = try ProcessRunner.run(argv: [executable] + arguments, workingDirectory: directory,
            home: directory.appendingPathComponent("home"), temporary: directory.appendingPathComponent("tmp"),
            stdout: stdout, stderr: stderr, timeout: 30, maxLogBytes: 1024 * 1024,
            jobID: "control-plane", cancellation: CancellationToken(),
            environmentOverrides: ProcessInfo.processInfo.environment["DEVELOPER_DIR"].map { ["DEVELOPER_DIR": $0] } ?? [:])
        guard outcome.reason == .exited, outcome.exitCode == 0, outcome.processGroupGone else {
            let detail = outcome.launchError.map { Data($0.utf8) }
                ?? (try? SafeFiles.readRegular(stderr, limit: 1024 * 1024)) ?? Data()
            throw SandboxError("control-plane tool failed: \(executable): \(String(decoding: detail.prefix(4096), as: UTF8.self))")
        }
        return try SafeFiles.readRegular(stdout, limit: 1024 * 1024)
    }
}

public struct InstalledClang: Codable {
    public let compiler: String
    public let cxxCompiler: String
    public let sdk: String
    public var cmake: String? = nil
    public var ninja: String? = nil
    public var buildToolsDirectory: String? = nil
    public var metalCompiler: String? = nil
    public var metallib: String? = nil
    public var metalToolchainDirectory: String? {
        guard let metalCompiler, let range = metalCompiler.range(of: ".xctoolchain/") else { return nil }
        let prefix = String(metalCompiler[..<range.upperBound])
        // Foundation may preserve /var aliases. The kernel policy requires the
        // actual /private/var cryptex path, not its user-facing spelling.
        guard let canonical = realpath(prefix, nil) else { return nil }
        defer { free(canonical) }
        return String(cString: canonical)
    }
    public var searchDirectories: [String] {
        [metalCompiler].compactMap { $0.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } }
        + [URL(fileURLWithPath: compiler).deletingLastPathComponent().path]
        + [buildToolsDirectory].compactMap { $0 }
        + [cmake, ninja].compactMap { $0.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } }
        + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }
    public var environment: [String: String] {
        ["PATH": searchDirectories.joined(separator: ":"), "CC": compiler, "CXX": cxxCompiler, "SDKROOT": sdk]
    }
    public static func resolve(logDirectory: URL) throws -> InstalledClang {
        func resolve(_ arguments: [String]) throws -> String {
            let data = try ControlPlaneTool.run("/usr/bin/xcrun", arguments, logs: logDirectory)
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\0"),
                  FileManager.default.fileExists(atPath: path) else { throw SandboxError("invalid installed toolchain path") }
            return path
        }
        var result = try InstalledClang(compiler: resolve(["--find", "clang"]), cxxCompiler: resolve(["--find", "clang++"]),
                                        sdk: resolve(["--show-sdk-path"]))
        func installed(_ relative: String) -> String? {
            let path = DevelopmentPolicy.toolsRoot.appendingPathComponent(relative).path
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        result.cmake = installed("cmake/CMake.app/Contents/bin/cmake")
        result.ninja = installed("ninja/ninja")
        result.buildToolsDirectory = URL(fileURLWithPath: try resolve(["--find", "make"])).deletingLastPathComponent().path
        // New Xcode releases install Metal as an optional cryptex toolchain.
        // Do not select Xcode's placeholder `metal` unless metallib also exists.
        if let metal = try? resolve(["--find", "metal"]), let library = try? resolve(["--find", "metallib"]),
           metal.contains(".xctoolchain/"),
           URL(fileURLWithPath: metal).deletingLastPathComponent() == URL(fileURLWithPath: library).deletingLastPathComponent() {
            result.metalCompiler = metal; result.metallib = library
        }
        return result
    }
}

private struct PublicationRecord: Codable {
    var instanceID: String
    var app: String
    var logicalID: String? = nil
    var sourcePath: String?
    var sourceSHA256: String?
    var signedSHA256: String?
    var policy = "scoped native development host; fixed inherited evaluation helper; fresh bundle; no quarantine removal"
}

/// Role-free factory for the experimental runtime. Never modifies a live bundle
/// or accepts entitlements, signing flags, bundle IDs or host paths from an Agent.
public final class AppSandboxFactory {
    private let binaries: [String: Data]
    private let directory: URL
    private let scheduler: ExecutionScheduler
    private let toolchain: InstalledClang
    public init(binDirectory: URL, directory: URL, scheduler: ExecutionScheduler) throws {
        guard getuid() != 0 else { throw SandboxError("do not run the sandbox controller as root") }
        self.directory = directory; self.scheduler = scheduler
        self.toolchain = try InstalledClang.resolve(logDirectory: directory.appendingPathComponent("toolchain_logs"))
        var binaries: [String: Data] = [:]
        for name in ["sandbox-host", "sandbox-probe", "metal-runner", "sandbox-shell"] {
            binaries[name] = try SafeFiles.readRegular(binDirectory.appendingPathComponent(name), limit: 64 * 1024 * 1024)
        }
        self.binaries = binaries
        try SafeFiles.secureDirectory(directory)
    }

    public func create(logicalID: String? = nil, candidate: WorkspaceFile? = nil, networkClient: Bool = false, taskPolicy: TaskPolicy? = nil, sharedWorkspace: SharedWorkspace? = nil, onAllocated: ((String) throws -> Void)? = nil) throws -> AppSandboxSession {
        let identifier = "local.metal-sandbox.instance-" + UUID().uuidString.lowercased()
        try onAllocated?(identifier)
        return try make(identifier: identifier, publication: directory.appendingPathComponent(identifier),
                        stateDirectory: directory.appendingPathComponent("instances"), candidate: candidate, logicalID: logicalID, networkClient: networkClient, taskPolicy: taskPolicy, sharedWorkspace: sharedWorkspace)
    }

    /// Reopen an owned, inactive development container using current trusted
    /// binaries. Never copy a checkpoint over its workspace or private HOME.
    public func start(_ previous: HostInfoReply, logicalID: String, networkClient: Bool, taskPolicy: TaskPolicy, fileOnly: Bool = false, sharedWorkspace: SharedWorkspace? = nil) throws -> AppSandboxSession {
        let identifier = previous.bundleID
        try Self.validateInstanceIdentifier(identifier)
        let publication = directory.appendingPathComponent(identifier)
        let app = publication.appendingPathComponent("sandbox_host.app")
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/\(identifier)/Data")
        let base = home.appendingPathComponent("Library/Application Support/MetalSandbox")
        guard previous.uid == getuid(), previous.bundle == app.path, previous.home == home.path,
              previous.workspace == (sharedWorkspace?.workspace ?? base.appendingPathComponent("workspace")).path else {
            throw SandboxError("saved instance paths or ownership do not match this service")
        }
        // Checking an old PID is conservative: an unrelated reused PID also
        // blocks startup. Never signal a process based on persisted identity.
        guard previous.pid > 0, kill(previous.pid, 0) == -1, errno == ESRCH else {
            throw SandboxError("previous Host PID still exists or cannot be verified; inspect processes before starting")
        }
        for path in [publication, home.deletingLastPathComponent(), home, base,
                     sharedWorkspace?.workspace ?? base.appendingPathComponent("workspace"), sharedWorkspace?.home ?? base.appendingPathComponent("home")] {
            var st = stat()
            guard lstat(path.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(),
                  path.resolvingSymlinksInPath().path == path.path else {
                throw SandboxError("original instance directory is missing or unsafe; refusing an empty replacement")
            }
        }
        let saved = try SafeFiles.read(PublicationRecord.self, from: publication.appendingPathComponent("publication.json"))
        guard saved.instanceID == identifier, saved.app == app.path,
              saved.logicalID == nil || saved.logicalID == logicalID,
              saved.sourcePath == nil, saved.sourceSHA256 == nil, saved.signedSHA256 == nil else {
            throw SandboxError("publication is not an owned development Host; use snapshot cloning instead")
        }
        return try make(identifier: identifier, publication: publication,
                        stateDirectory: directory.appendingPathComponent("instances"), candidate: nil,
                        logicalID: logicalID, networkClient: networkClient, taskPolicy: taskPolicy, replacing: true, fileOnly: fileOnly, sharedWorkspace: sharedWorkspace)
    }

    public static func validateInstanceIdentifier(_ identifier: String) throws {
        let prefix = "local.metal-sandbox.instance-"
        guard identifier.hasPrefix(prefix), UUID(uuidString: String(identifier.dropFirst(prefix.count))) != nil,
              identifier == identifier.lowercased() else { throw SandboxError("invalid owned physical identity") }
    }

    /// A freshly signed maintenance Host uses the stopped revision's identity
    /// to purge inside App Sandbox. It never launches the old candidate, edits
    /// the old signed bundle, or traverses the container from this process.
    public func purge(_ identifier: String, logicalID: String? = nil, sharedWorkspace: SharedWorkspace? = nil, removeSharedFiles: Bool = false) throws -> String? {
        try Self.validateInstanceIdentifier(identifier)
        let publication = directory.appendingPathComponent(identifier).appendingPathComponent("publication.json")
        let owner = try logicalID ?? (FileManager.default.fileExists(atPath: publication.path)
            ? SafeFiles.read(PublicationRecord.self, from: publication).logicalID : nil)
        let maintenance = directory.appendingPathComponent("delete_" + UUID().uuidString.lowercased())
        let session = try make(identifier: identifier, publication: maintenance,
                               stateDirectory: maintenance.appendingPathComponent("session"), candidate: nil, logicalID: owner, fileOnly: true, sharedWorkspace: sharedWorkspace)
        do { try session.purgeContainer(sharedWorkspace: removeSharedFiles) }
        catch {
            do { try session.close() }
            catch { try? scheduler.requireInspection("maintenance Host cleanup failed: \(error)") }
            throw error
        }
        do { try session.close() }
        catch { try? scheduler.requireInspection("maintenance Host cleanup failed: \(error)"); throw error }
        var warning: String?
        do { try ContainerShell.remove(identifier) }
        catch let denied as ContainerShellPermissionDenied { warning = denied.description }
        let original = directory.appendingPathComponent(identifier)
        if FileManager.default.fileExists(atPath: original.path) { try FileManager.default.removeItem(at: original) }
        try FileManager.default.removeItem(at: maintenance)
        return warning
    }

    /// Only trusted control-plane publications in this state directory are
    /// inventoried. A matching Containers prefix alone is never ownership.
    public func allocatedIdentifiers() throws -> [String] {
        var result: [String] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let identifier = url.lastPathComponent
            guard identifier.hasPrefix("local.metal-sandbox.instance-") else { continue }
            try Self.validateInstanceIdentifier(identifier)
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { throw SandboxError("unsafe runtime publication directory") }
            let publication = try SafeFiles.read(PublicationRecord.self, from: url.appendingPathComponent("publication.json"))
            guard publication.instanceID == identifier,
                  publication.app == url.appendingPathComponent("sandbox_host.app").path else { throw SandboxError("publication identity mismatch") }
            result.append(identifier)
        }
        return result.sorted()
    }

    private func make(identifier: String, publication: URL, stateDirectory: URL, candidate: WorkspaceFile?, logicalID: String?, networkClient: Bool = false, taskPolicy: TaskPolicy? = nil, replacing: Bool = false, fileOnly: Bool = false, sharedWorkspace: SharedWorkspace? = nil) throws -> AppSandboxSession {
        try sharedWorkspace?.verify()
        try Self.validateInstanceIdentifier(identifier)
        if let logicalID {
            guard logicalID.hasPrefix("sbx-"), let uuid = UUID(uuidString: String(logicalID.dropFirst(4))),
                  logicalID == "sbx-" + uuid.uuidString.lowercased() else { throw SandboxError("invalid logical sandbox ID") }
        }
        let displayName = "MetalSandboxHost" + (logicalID.map { "-" + $0 } ?? "")
        if !fileOnly, let reason = scheduler.recoveryReason { throw SandboxError("node quarantined: \(reason)") }
        if let candidate { try PublishedCandidate.validate(candidate) }
        // A collision must fail rather than overwrite an app/state from an older
        // incarnation. OS-managed containers are retained, not blindly deleted.
        let staging = replacing ? directory.appendingPathComponent("start_" + UUID().uuidString.lowercased()) : publication
        guard mkdir(staging.path, 0o700) == 0 else { throw SandboxError("cannot create fresh publication directory") }
        defer { if replacing { try? FileManager.default.removeItem(at: staging) } }
        let app = staging.appendingPathComponent("sandbox_host.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let resources = app.appendingPathComponent("Contents/Resources")
        try SafeFiles.secureDirectory(macOS); try SafeFiles.secureDirectory(resources)
        func plist(_ value: [String: Any], _ url: URL) throws {
            try SafeFiles.writeData(PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0), to: url)
        }
        try plist(["CFBundleIdentifier": identifier, "CFBundleName": displayName, "CFBundleDisplayName": displayName,
                   "CFBundleExecutable": "sandbox-host", "CFBundlePackageType": "APPL",
                   "CFBundleVersion": MetalSandboxVersion.bundleBuild,
                   "CFBundleShortVersionString": MetalSandboxVersion.bundleShortVersion,
                   "MetalSandboxVersion": MetalSandboxVersion.current,
                   "LSUIElement": true, "LSMinimumSystemVersion": "13.0"],
                  app.appendingPathComponent("Contents/Info.plist"))
        let hostEntitlements = resources.appendingPathComponent("host.entitlements")
        let childEntitlements = resources.appendingPathComponent("child.entitlements")
        try plist(DevelopmentPolicy.hostEntitlements(identifier: identifier, toolchain: toolchain, networkClient: networkClient, sharedWorkspace: sharedWorkspace), hostEntitlements)
        try plist(["com.apple.security.app-sandbox": true, "com.apple.security.inherit": true], childEntitlements)
        try SafeFiles.write(toolchain, to: resources.appendingPathComponent("development_toolchain.json"))
        try SafeFiles.write(taskPolicy ?? scheduler.taskPolicy, to: resources.appendingPathComponent("task_policy.json"))
        if let sharedWorkspace { try SafeFiles.write(sharedWorkspace, to: resources.appendingPathComponent("shared_workspace.json")) }
        let shellHelper = publication.appendingPathComponent("sandbox_host.app/Contents/MacOS/sandbox-shell").path
        try AgentHarnesses.installResources(at: resources, helper: shellHelper)
        var files = binaries
        if let candidate { files["candidate"] = candidate.data }
        for (name, data) in files {
            let file = macOS.appendingPathComponent(name)
            try SafeFiles.writeData(data, to: file)
            guard chmod(file.path, 0o700) == 0 else { throw SandboxError("cannot set runtime executable mode") }
        }
        let logs = staging.appendingPathComponent("signing_logs")
        for name in files.keys.sorted() where name != "sandbox-host" {
            _ = try ControlPlaneTool.run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements",
                childEntitlements.path, macOS.appendingPathComponent(name).path], logs: logs)
        }
        _ = try ControlPlaneTool.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier,
            "--entitlements", hostEntitlements.path, app.path], logs: logs)
        _ = try ControlPlaneTool.run("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path], logs: logs)
        var published: PublishedCandidate?
        if let candidate {
            let binary = macOS.appendingPathComponent("candidate")
            try AppSignature.verify(binary, inherited: true)
            let signed = try SafeFiles.readRegular(binary, limit: .max)
            published = PublishedCandidate(source: candidate, sourceSHA256: PublishedCandidate.digest(candidate.data),
                                           signedSHA256: PublishedCandidate.digest(signed))
        }
        let installedApp = publication.appendingPathComponent("sandbox_host.app")
        try SafeFiles.write(PublicationRecord(instanceID: identifier, app: installedApp.path, logicalID: logicalID, sourcePath: candidate?.path,
            sourceSHA256: published?.sourceSHA256, signedSHA256: published?.signedSHA256),
            to: staging.appendingPathComponent("publication.json"))
        if replacing {
            // Atomic exchange keeps a valid canonical publication even if the
            // daemon exits during upgrade. Only signed runtime files move.
            guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, publication.path, UInt32(RENAME_SWAP)) == 0 else {
                throw SandboxError("cannot atomically replace stopped Host publication")
            }
        }
        // Direct executable launch does not guarantee Launch Services has
        // indexed this freshly signed bundle before its container is shown.
        let registration = LSRegisterURL(installedApp as CFURL, true)
        if registration != noErr {
            FileHandle.standardError.write(Data("warning: sandbox display-name registration failed (\(registration)): \(identifier)\n".utf8))
        }
        return try AppSandboxSession(app: installedApp, stateDirectory: stateDirectory,
                                     scheduler: scheduler, toolchain: toolchain, publishedCandidate: published, networkClient: networkClient, taskPolicy: taskPolicy, fileOnly: fileOnly)
    }
}
