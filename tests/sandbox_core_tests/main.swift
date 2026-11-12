import Foundation
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--native-shell-disconnect" {
    guard arguments.count == 3 else { exit(2) }
    do { try runNativeShellDisconnectTests(bin: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2])); exit(0) }
    catch { print("native shell disconnect tests: \(error)"); exit(1) }
}
if arguments.first == "--native-recovery" {
    guard arguments.count == 3 else { exit(2) }
    do { try runNativeRecoveryTests(bin: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2])); exit(0) }
    catch { print("native recovery tests: \(error)"); exit(1) }
}
if arguments.first == "--native-cleanup" {
    guard arguments.count == 3 else { exit(2) }
    do { try runNativeProcessCleanupTests(bin: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2])); exit(0) }
    catch { print("native cleanup tests: \(error)"); exit(1) }
}
if arguments.first == "--loopback-forwards" {
    guard arguments.count == 2, let port = Int(arguments[1]) else { exit(2) }
    do { try runLoopbackTests(port: port); exit(0) }
    catch { print("loopback tests: \(error)"); exit(1) }
}
if arguments.first == "--ssh-forward" {
    guard arguments.count == 4, let source = Int(arguments[2]), let listen = Int(arguments[3]) else { exit(2) }
    do { try runSSHForwardTest(node: URL(fileURLWithPath: arguments[1]), sourcePort: source, listenPort: listen); exit(0) }
    catch { print("SSH forward tests: \(error)"); exit(1) }
}
if arguments.first == "--cluster-read-retry" {
    guard arguments.count == 3 else { exit(2) }
    do { try runClusterReadRetryTests(bin: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2])); exit(0) }
    catch { print("cluster read retry tests: \(error)"); exit(1) }
}
if arguments.first == "--cluster-capacity" {
    guard arguments.count == 3 else { exit(2) }
    do { try runClusterCapacityTests(bin: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2])); exit(0) }
    catch { print("cluster capacity tests: \(error)"); exit(1) }
}
if arguments.first == "--cluster" {
    guard arguments.count == 3 else { exit(2) }
    do { try runClusterTests(bin: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2])); exit(0) }
    catch { FileHandle.standardError.write(Data("cluster tests: \(error)\n".utf8)); exit(1) }
}
if arguments.first == "--cluster-index" {
    guard arguments.count == 3 else { exit(2) }
    do { try runClusterIndexTests(bin: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2])); exit(0) }
    catch { print("cluster index tests: \(error)"); exit(1) }
}
if arguments.first == "--native-shell-counts" {
    guard arguments.count == 3 else { exit(2) }
    do { try runShellTaskCounts(bin: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2])); exit(0) }
    catch { print("native shell counts: \(error)"); exit(1) }
}
if arguments.first == "--native-file-only" {
    guard arguments.count == 3 else { print("sandbox-selftest --native-file-only BIN_DIR NEW_OUTPUT_DIR"); exit(2) }
    do { try runFileOnlyHost(bin: URL(fileURLWithPath: arguments[1]).standardizedFileURL, output: URL(fileURLWithPath: arguments[2]).standardizedFileURL); exit(0) }
    catch { FileHandle.standardError.write(Data("file-only test: \(error)\n".utf8)); exit(1) }
}
if arguments.first == "--native-host-exit" {
    guard arguments.count == 3 else { print("sandbox-selftest --native-host-exit BIN_DIR NEW_OUTPUT_DIR"); exit(2) }
    do {
        try runHostExitDiagnostics(bin: URL(fileURLWithPath: arguments[1]).standardizedFileURL,
                                  output: URL(fileURLWithPath: arguments[2]).standardizedFileURL)
        exit(0)
    } catch { FileHandle.standardError.write(Data("host-exit test: \(error)\n".utf8)); exit(1) }
}
if arguments.first == "--native-file-reads" {
    guard arguments.count == 3 else { print("sandbox-selftest --native-file-reads BIN_DIR NEW_OUTPUT_DIR"); exit(2) }
    do {
        try runLiveFileReads(bin: URL(fileURLWithPath: arguments[1]).standardizedFileURL,
                            output: URL(fileURLWithPath: arguments[2]).standardizedFileURL)
        exit(0)
    } catch { FileHandle.standardError.write(Data("live-file-read test: \(error)\n".utf8)); exit(1) }
}

let tests: [(String, (CoreTests) throws -> Void)] = [
    ("release metadata", { try $0.testReleaseMetadata() }),
    ("loopback forward owner reconnect", { _ in try runLoopbackOwnerReconnectTest() }),
    ("cluster relay retries read-only requests", { _ in try runClusterRelayRetryTest() }),
    ("host memory and storage utilization", { try $0.testHostMemoryAndStorageUtilization() }),
    ("bounded regular file reader", { try $0.testRegularReaderRejectsSymlinkAndOversize() }),
    ("exclusive lease", { try $0.testLeaseRejectsSecondOwner() }),
]
var failedTests = 0
for (name, body) in tests {
    print("TEST \(name)")
    let before = assertionFailures.count
    let test = CoreTests()
    do { try test.setUpWithError(); try body(test) }
    catch { fail("uncaught test error: \(error)") }
    do { try test.tearDownWithError() } catch { fail("teardown error: \(error)") }
    if assertionFailures.count == before { print("  PASS") } else { failedTests += 1 }
}
let runtimeTests: [(String, (RuntimeTests) throws -> Void)] = [
    ("workspace reveal confinement and lightweight execution summary", { try $0.revealValidation() }),
    ("instance environment validation and non-persistent execution payload", { try $0.environmentVariables() }),
    ("harness adapters: hooks, resources, selection and provider-neutral trajectory access", { try $0.agentHarness() }),
    ("trajectory log discovery, chunking, cursor resets and confinement", { try $0.trajectory() }),
    ("cancellation delivered with clean child exit remains cancelled", { try $0.cancellationAtExit() }),
    ("runtime relative paths and command validation", { try $0.paths() }),
    ("confined workspace read/write/export", { try $0.fileRoundtrip() }),
    ("streamed large archives and integrity-preserving failures", { try $0.streamingArchive() }),
    ("task folder import, ZIP rejection and reject-before-import", { try $0.taskPackages() }),
    ("verification imports only tests and persists its execution label", { try $0.verificationPackages() }),
    ("snapshot preserves empty directories and rejects traversal, collisions and linked parents", { try $0.emptyDirectorySnapshots() }),
    ("chunked transfers drain failures without losing framing", { try $0.streamingFrames() }),
    ("confined symlink/hardlink/FIFO rejection", { try $0.links() }),
    ("workspace metadata, links, large files and pagination", { try $0.directoryListing() }),
    ("drained container shell deletion rejects unknown files and never follows Desktop links", { try $0.containerShell() }),
    ("Finder targets are exact real directories without mutations or symlink following", { try $0.containerLocations() }),
    ("optional instance names, replica numbering and persistence", { try $0.instanceNames() }),
    ("directory FD remains pinned after root rename", { try $0.pinnedDirectory() }),
    ("permanent purge is pinned and does not follow symlinks or truncate hardlinks", { try $0.purgeWorkspace() }),
    ("bounded framed IPC and absolute deadline", { try $0.framing() }),
    ("independent execution scheduler serializes launches", { try $0.leaseSerialization() }),
    ("compound shell allowlist checks every static component", { try $0.compoundShellTaskPolicy() }),
    ("task allowlist uses exact paths and argument prefixes", { try $0.taskAllowlist() }),
    ("network opt-in changes only the client entitlement", { try $0.networkPolicy() }),
    ("allowlisted leases run alongside the serial slot", { try $0.parallelAllowlistLeases() }),
    ("four task counters, pre-dispatch registration, thermal wait, ownership and cancellation", { try $0.executionCountBreakdown() }),
    ("queued deadlines retire before the running task; lifecycle actions and structured errors", { try $0.queuedDeadlineAndLifecycle() }),
    ("parallel leases retain fail-closed recovery", { try $0.parallelLeaseRecovery() }),
    ("scheduler quarantines uncertain completion", { try $0.quarantine() }),
    ("cleaned failures release both lanes; uncertain cleanup remains quarantined", { try $0.interruptionCleanup() }),
    ("critical heat pauses admission without quarantining; cooldown, cancellation and deadlines", { try $0.thermalPause() }),
    ("scheduler cancellation and stale lease", { try $0.cancellationAndStaleLease() }),
    ("artifact integrity and conflicting path rejection", { try $0.artifacts() }),
    ("scoped instance authorization and stale handle rejection", { try $0.scopedRegistry() }),
    ("live reads overlap execution; mutations and full snapshots remain exclusive", { try $0.readsDuringExecution() }),
    ("scripted multi-turn freeze/verify/trace loop (mock)", { try $0.episode() }),
    ("fresh verifier instance and cleanup guards (mock)", { try $0.episodeGuards() }),
    ("publication rejects unsafe paths and non-executable formats", { try $0.publicationInput() }),
    ("failed development shutdown prevents verifier publication (mock)", { try $0.freezeCloseFailure() }),
    ("concurrent private-pipe sends preserve frame boundaries", { try $0.concurrentFrames() }),
    ("recovery requires confirmation and archives lease evidence", { try $0.explicitRecovery() }),
]
for (name, body) in runtimeTests {
    print("TEST \(name)")
    let before = assertionFailures.count
    do { let test = try RuntimeTests(); try body(test) }
    catch { fail("uncaught test error: \(error)") }
    if assertionFailures.count == before { print("  PASS") } else { failedTests += 1 }
}
let totalTests = tests.count + runtimeTests.count
print("\n\(totalTests - failedTests)/\(totalTests) tests passed; \(assertionFailures.count) assertion failures")
exit(failedTests == 0 ? 0 : 1)
