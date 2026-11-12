import Foundation
import Darwin
import SandboxCore
import SandboxRuntime
import EvaluationCore

// 固定可信用例通过共享调度器，在签名的 App Sandbox 内编译和运行程序。
let metalSource = #"""
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--probe")) {
        for (int i = 2; i < argc; ++i) {
            int fd = open(argv[i], O_RDONLY);
            if (fd >= 0) { close(fd); puts("allowed"); }
            else if (errno == EPERM || errno == EACCES) { puts("denied"); }
            else { return 9; }
        }
        return 0;
    }
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 10;
        NSError *error = nil;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void fill(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {"
            "if (i < 257) out[i] = i * 3u + 7u; }";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { fprintf(stderr, "%s\n", error.description.UTF8String); return 11; }
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:
            [library newFunctionWithName:@"fill"] error:&error];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLBuffer> output = [device newBufferWithLength:257 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        if (!pipeline || !queue || !output) return 12;
        for (int frame = 0; frame < 1000; ++frame) {
            @autoreleasepool {
                id<MTLCommandBuffer> buffer = [queue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
                if (!buffer || !encoder) return 13;
                [encoder setComputePipelineState:pipeline];
                [encoder setBuffer:output offset:0 atIndex:0];
                [encoder dispatchThreads:MTLSizeMake(257, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
                [encoder endEncoding]; [buffer commit]; [buffer waitUntilCompleted];
                if (buffer.status != MTLCommandBufferStatusCompleted) return 14;
            }
        }
        fprintf(stderr, "metal_device=%s\ncompleted_compute_iterations=1000\n", device.name.UTF8String);
        return fwrite(output.contents, sizeof(uint32_t), 257, stdout) == 257 ? 0 : 15;
    }
}
"""#

struct RepairingFixtureAgent: AgentDriver {
    let build: NativeCommand
    var step = 0
    private(set) var observedCompilerFailure = false
    private(set) var observedCompilerSuccess = false
    mutating func next(observation: ToolObservation?) throws -> AgentAction {
        defer { step += 1 }
        switch step {
        case 0: return .write(WorkspaceFile(path: "source.mm", data: Data("#error deliberate_fixture_error\n".utf8)))
        case 1: return .exec(build)
        case 2:
            guard let result = observation?.execution, result.outcome.reason == .exited,
                  result.outcome.exitCode != 0,
                  String(decoding: result.stderr, as: UTF8.self).contains("deliberate_fixture_error") else {
                throw SandboxError("fixture did not receive the expected real compiler diagnostic")
            }
            observedCompilerFailure = true
            return .write(WorkspaceFile(path: "source.mm", data: Data(metalSource.utf8)))
        case 3: return .exec(build)
        default:
            guard let result = observation?.execution, result.outcome.reason == .exited,
                  result.outcome.exitCode == 0 else { throw SandboxError("corrected native compilation failed") }
            observedCompilerSuccess = true
            return .finish
        }
    }
}

private final class NativeFixtureVerifier: Verifier {
    let controllerCanary: String
    let developmentCanary: String
    var stalePublicationRejected = false
    var boundaryExecution: NativeResult?
    init(controllerCanary: String, developmentCanary: String) {
        self.controllerCanary = controllerCanary; self.developmentCanary = developmentCanary
    }
    func verify(in sandbox: SandboxSession) throws -> VerificationResult {
        let original = try sandbox.read("fixture_program")
        // A stale publication must be rejected before acquiring a GPU lease.
        try sandbox.write(WorkspaceFile(path: "fixture_program", data: Data("changed".utf8), executable: true))
        do { _ = try sandbox.execute(NativeCommand(["./fixture_program"])) }
        catch {
            guard String(describing: error).contains("differs from its frozen publication") else { throw error }
            stalePublicationRejected = true
        }
        guard stalePublicationRejected else { throw SandboxError("runtime executed a stale publication") }
        try sandbox.write(original)
        let boundary = try sandbox.execute(NativeCommand(["./fixture_program", "--probe", "source.mm", controllerCanary, developmentCanary]))
        boundaryExecution = boundary
        guard boundary.outcome.reason == .exited, boundary.outcome.exitCode == 0,
              boundary.stdout == Data("allowed\ndenied\ndenied\n".utf8) else {
            throw SandboxError("published candidate filesystem boundary check failed")
        }
        var expected = Data()
        for i in 0..<257 {
            var value = UInt32(i * 3 + 7).littleEndian
            expected.append(withUnsafeBytes(of: &value) { Data($0) })
        }
        return try OutputVerifier(command: NativeCommand(["./fixture_program"], timeoutSeconds: 120), expected: expected).verify(in: sandbox)
    }
}

private struct NativeSmokeReport: Codable {
    var host: HostInfo
    var result = "running"
    var fixture = "observation-driven compiler repair -> freeze -> fresh native verifier; NOT a model evaluation"
    var toolchain: InstalledClang?
    var instances: [HostInfoReply] = []
    var checks: [String] = []
    var episode: EpisodeReport?
    var boundaryExecution: NativeResult?
    var error: String?
}

func runNativeSmoke(binDirectory: URL, output: URL) throws -> Int32 {
    guard getuid() != 0 else { throw SandboxError("do not run as root") }
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SandboxError("acceptance output already exists") }
    try SafeFiles.secureDirectory(output)
    let resultURL = output.appendingPathComponent("native_smoke.json")
    var report = NativeSmokeReport(host: HostInfo.capture())
    try SafeFiles.write(report, to: resultURL)
    do {
        let scheduler = try ExecutionScheduler()
        guard scheduler.recoveryReason == nil else { throw SandboxError("node recovery inspection required") }
        let toolchain = try InstalledClang.resolve(logDirectory: output.appendingPathComponent("toolchain_logs"))
        report.toolchain = toolchain
        let factory = try AppSandboxFactory(binDirectory: binDirectory,
            directory: output.appendingPathComponent("runtimes"), scheduler: scheduler)
        let registry = SandboxRegistry()
        let working = try factory.create()
        let owner = try registry.register(working)
        let client = registry.client(owner)
        // Covers activation/setup errors before EpisodeController takes ownership.
        defer { try? client.close() }
        report.instances.append(working.info)
        let readOnly = registry.client(try registry.grant(owner, operations: [.read]))
        func requireCapabilityRejection(_ operation: () throws -> Void) throws {
            do { try operation() }
            catch {
                guard String(describing: error).contains("unknown, stale or insufficient sandbox capability") else { throw error }
                return
            }
            throw SandboxError("scoped native client allowed an unauthorized operation")
        }
        try requireCapabilityRejection { _ = try readOnly.execute(NativeCommand(["/bin/echo", "must-not-run"])) }
        try requireCapabilityRejection { try readOnly.write(WorkspaceFile(path: "forbidden", data: Data())) }
        let canary = output.appendingPathComponent("controller_canary")
        try SafeFiles.writeData(Data("controller-only".utf8), to: canary)
        let verifier = NativeFixtureVerifier(controllerCanary: canary.path,
            developmentCanary: working.info.workspace + "/source.mm")
        let store = try ArtifactStore(directory: output.appendingPathComponent("artifacts"))
        let controller = try EpisodeController(directory: output.appendingPathComponent("episodes"), store: store)
        var agent = RepairingFixtureAgent(build: NativeCommand([toolchain.cxxCompiler, "-isysroot", toolchain.sdk,
            "-mmacosx-version-min=13.0", "-std=c++17", "-fobjc-arc", "-framework", "Foundation", "-framework", "Metal",
            "source.mm", "-o", "fixture_program"], timeoutSeconds: 120))
        let episode = try controller.run(agent: &agent, working: client, makeVerifierSandbox: { frozen in
            guard let candidate = frozen.files.first(where: { $0.path == "fixture_program" }) else {
                throw SandboxError("frozen artifact missing compiled executable")
            }
            let fresh = try factory.create(candidate: candidate)
            do {
                let handle = try registry.register(fresh)
                report.instances.append(fresh.info)
                return registry.client(handle)
            } catch { try? fresh.close(); throw error }
        }, verifier: verifier, maxTurns: 8, budgetSeconds: 300)
        report.episode = episode
        report.boundaryExecution = verifier.boundaryExecution
        try requireCapabilityRejection { _ = try readOnly.read("source.mm") }
        guard episode.state == "succeeded", agent.observedCompilerFailure, agent.observedCompilerSuccess,
              verifier.stalePublicationRejected, scheduler.recoveryReason == nil,
              report.instances.count == 2, report.instances[0].home != report.instances[1].home else {
            throw SandboxError("native episode failed: \(episode.error ?? episode.state)")
        }
        guard let artifactID = episode.artifactID,
              try store.load(artifactID).files.contains(where: { $0.path == "source.mm" && $0.data == Data(metalSource.utf8) }) else {
            throw SandboxError("frozen source integrity check failed")
        }
        report.checks = ["Swift factory/signature/session activation", "real compiler failure and observation-driven repair",
            "scoped native client write/exec denial and stopped-handle revocation",
            "frozen artifact hash verification", "development stopped before fresh verifier publication",
            "stale workspace executable rejected before lease", "compiled candidate own/controller/development canaries",
            "compiled Metal candidate: 1000 compute iterations and external 257-element readback check",
            "shared serial scheduler without recovery marker", "episode report and command/diagnostic trace saved"]
        report.result = "trusted_native_episode_passed"
    } catch {
        report.result = "failed"; report.error = String(describing: error)
    }
    try SafeFiles.write(report, to: resultURL)
    print("\(report.result)\nReport: \(resultURL.path)")
    if let error = report.error { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
    return report.result == "failed" ? 1 : 0
}
