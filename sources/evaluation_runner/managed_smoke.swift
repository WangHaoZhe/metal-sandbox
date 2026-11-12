import Foundation
import SandboxCore
import SandboxRuntime
import EvaluationCore

private struct ManagedFixtureVerifier: Verifier {
    let controllerCanary: String
    let developmentCanary: String
    func verify(in sandbox: SandboxSession) throws -> VerificationResult {
        let probe = try sandbox.execute(NativeCommand(["./fixture_program", "--probe", "source.mm", controllerCanary, developmentCanary]))
        guard probe.outcome.exitCode == 0, probe.stdout == Data("allowed\ndenied\ndenied\n".utf8) else {
            throw SandboxError("managed candidate crossed filesystem boundaries")
        }
        var expected = Data()
        for i in 0..<257 {
            var value = UInt32(i * 3 + 7).littleEndian
            expected.append(withUnsafeBytes(of: &value) { Data($0) })
        }
        return try OutputVerifier(command: NativeCommand(["./fixture_program"], timeoutSeconds: 120), expected: expected).verify(in: sandbox)
    }
}

func runManagedSmoke(state: URL, output: URL) throws -> Int32 {
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SandboxError("output directory already exists") }
    try SafeFiles.secureDirectory(output)
    let token = try NativeControlClient.operatorToken(stateDirectory: state)
    func admin(_ operation: String, _ configure: (inout NativeControlRequest) -> Void = { _ in }) throws -> NativeControlReply {
        var request = NativeControlRequest(operation); request.operatorToken = token
        configure(&request); return try NativeControlClient.request(request)
    }
    guard let status = try admin("status").status else { throw SandboxError("missing manager status") }
    try SafeFiles.write(status, to: output.appendingPathComponent("manager_status.json"))
    var created: [String] = []
    defer {
        // Covers setup/transport failures before the episode owns its sessions.
        for id in created { _ = try? admin("stop") { $0.instanceID = id } }
    }
    func create() throws -> (RemoteSandboxSession, NativeInstanceRecord) {
        guard let instance = try admin("create", { $0.count = 1 }).instances?.first else { throw SandboxError("missing created sandbox") }
        created.append(instance.id)
        guard let handle = try admin("grant", { $0.instanceID = instance.id; $0.operations = Set(SandboxOperation.allCases) }).handle else {
            throw SandboxError("missing episode-scoped handle")
        }
        return (RemoteSandboxSession(handle: handle), instance)
    }
    let (working, instance) = try create()
    let canary = output.appendingPathComponent("controller_canary")
    try SafeFiles.writeData(Data("controller-only".utf8), to: canary)
    let store = try ArtifactStore(directory: output.appendingPathComponent("artifacts"))
    let controller = try EpisodeController(directory: output.appendingPathComponent("episodes"), store: store)
    var agent = RepairingFixtureAgent(build: NativeCommand([status.toolchain.cxxCompiler, "-isysroot", status.toolchain.sdk,
        "-mmacosx-version-min=13.0", "-std=c++17", "-fobjc-arc", "-framework", "Foundation", "-framework", "Metal",
        "source.mm", "-o", "fixture_program"], timeoutSeconds: 120))
    let report = try controller.run(agent: &agent, working: working, makeVerifierSandbox: { _ in try create().0 },
        verifier: ManagedFixtureVerifier(controllerCanary: canary.path, developmentCanary: instance.physical!.workspace + "/source.mm"),
        maxTurns: 8, budgetSeconds: 300)
    try SafeFiles.write(report, to: output.appendingPathComponent("managed_episode.json"))
    print("\(report.state): \(output.appendingPathComponent("managed_episode.json").path)")
    if let error = report.error { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
    return report.state == "succeeded" ? 0 : 1
}
