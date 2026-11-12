import XCTest
import Combine
import AppKit
import SwiftUI
import FrontendCore
@testable import FrontendApp

@MainActor final class StateTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    private var instanceID: String!
    private var client: CLIClient { CLIClient(model.configuration) }

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let bin = environment["METAL_SANDBOX_TEST_BIN"], let state = environment["METAL_SANDBOX_TEST_STATE_DIR"] else {
            throw CLIError("Set METAL_SANDBOX_TEST_BIN and METAL_SANDBOX_TEST_STATE_DIR to an isolated running service")
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("frontend_state_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        model = AppModel(); model.directory = bin; model.stateDirectory = state
        model.clusterConfig = ""; model.maxConcurrentInstances = 32
        let policy = directory.appendingPathComponent("policy.json")
        try Data(#"{"parallel":[{"executable":"/bin/echo"},{"executable":"/bin/sleep","argumentPrefix":["30"]}]}"#.utf8).write(to: policy)
        let created = try await client.sandbox(["create", "--count", "1", "--no_network", "--task-policy", policy.path]).reply()
        instanceID = try XCTUnwrap(created.instances?.first?.id)
        try await write("setup.sh", "original")
        try await write("instruction.md", "task")
        try await client.replaceEnvironment(id: instanceID, values: ["TEST":"original"])
        await model.refresh()
        XCTAssertTrue(model.compatible)
    }

    override func tearDown() async throws {
        if let instanceID {
            let instances = try await client.sandbox(["list"]).reply().instances ?? []
            if let instance = instances.first(where: { $0.id == instanceID }) {
                if instance.isActive { _ = try await client.sandbox(["stop", instanceID]).checked() }
                _ = try await client.sandbox(["delete", instanceID, "--confirm"]).checked()
            }
        }
        model = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func write(_ path: String, _ text: String) async throws {
        let source = directory.appendingPathComponent(UUID().uuidString)
        try text.write(to: source, atomically: true, encoding: .utf8)
        _ = try await client.sandbox(["write", instanceID, path, "--from", source.path]).checked()
    }

    private func verify() async throws -> String {
        try await write("tests/test.sh", "printf 'verification output\\n'\n")
        let reply = try await client.sandbox(["verify", instanceID, "--detach"]).reply()
        let id = try XCTUnwrap(reply.execution?.id)
        _ = try await client.sandbox(["wait", id]).checked()
        return id
    }

    private func waitForCounts(serialRunning: Int, serialWaiting: Int, parallelRunning: Int) async throws {
        let deadline = Date(timeIntervalSinceNow: 15)
        while Date() < deadline {
            let counts = try await client.sandbox(["inspect", instanceID]).reply().instance?.executionCounts
            if counts?.serialRunning == serialRunning && counts?.serialWaiting == serialWaiting && counts?.parallelRunning == parallelRunning { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw CLIError("execution counts did not reach the expected state")
    }
    func testInterfaceLanguagePersistenceAndImmediateState() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: InterfaceLanguage.preferenceKey)
        let original = model.language
        defer {
            model.language = original
            if let saved { defaults.set(saved, forKey: InterfaceLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: InterfaceLanguage.preferenceKey) }
        }
        defaults.removeObject(forKey: InterfaceLanguage.preferenceKey)
        XCTAssertEqual(AppModel().language, .system)
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW", "en-US"]), .chinese)
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferredLanguages: ["en-US", "zh-Hans"]), .english)
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferredLanguages: []), .english)
        XCTAssertEqual(InterfaceLanguage.english.resolved(preferredLanguages: ["zh-Hans"]), .english)
        let configuration = model.configuration
        let instance = try XCTUnwrap(model.instances.first { $0.id == instanceID })
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        for (language, state, title) in [(InterfaceLanguage.english, "Active", "Read Task Instruction"), (.chinese, "可用", "读取题目")] {
            model.language = language
            XCTAssertEqual(InterfaceLanguage.current, language)
            XCTAssertEqual(AppModel().language, language)
            XCTAssertEqual(instance.displayState, state)
            XCTAssertEqual(ConsoleTemplate.readPrompt.title, title)
            XCTAssertEqual(model.configuration, configuration)
            XCTAssertEqual(model.instances.map(\.id), [instanceID])
            let help = try await client.run(.sandbox, ["--help"]).checked().text
            XCTAssertTrue(help.contains("Usage: sandboxctl"))
            XCTAssertFalse(help.contains("用法"))
        }
        model.language = .system
        XCTAssertEqual(AppModel().language, .system)
        XCTAssertEqual(model.language.locale, InterfaceLanguage.system.locale)
        XCTAssertEqual(changes, 3)
        withExtendedLifetime(subscription) {}
    }


    func testAppModelDoesNotPublishUnchangedRefreshes() async throws {
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        for _ in 0..<3 {
            try await Task.sleep(nanoseconds: 1_100_000_000)
            await model.refresh()
        }
        XCTAssertEqual(changes, 0)
        _ = try await client.sandbox(["stop", instanceID]).checked()
        await model.refresh()
        XCTAssertGreaterThan(changes, 0)
        XCTAssertTrue(try XCTUnwrap(model.instances.first { $0.id == instanceID }).canStart)
        withExtendedLifetime(subscription) {}
    }

    func testNodeUtilizationThroughRealService() async throws {
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let reply = try await client.sandbox(["status"]).reply()
        let status = try XCTUnwrap(reply.status)
        let utilization = try XCTUnwrap(status.host.utilization)
        let cpu = try XCTUnwrap(utilization.cpuPercent)
        XCTAssertTrue(cpu.isFinite && (0...100).contains(cpu))
        if let gpu = utilization.gpuPercent {
            XCTAssertTrue(gpu.isFinite && (0...100).contains(gpu))
        }
        let memoryUsed = try XCTUnwrap(utilization.memoryUsedBytes), memoryTotal = try XCTUnwrap(utilization.memoryTotalBytes)
        XCTAssertEqual(memoryTotal, status.host.memoryBytes)
        XCTAssertTrue(memoryUsed > 0 && memoryUsed <= memoryTotal)
        let storageUsed = try XCTUnwrap(utilization.storageUsedBytes), storageTotal = try XCTUnwrap(utilization.storageTotalBytes)
        XCTAssertTrue(storageUsed > 0 && storageUsed <= storageTotal)
        for width in [360.0, 820.0] {
            let view = NodeEnvironmentView(status: status, connected: true, monitor: NodeUtilizationMonitor(utilization)).padding(12).frame(width: width)
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, Int(width * 2))
            XCTAssertGreaterThan(image.height, 100)
        }
    }

    func testClusterConfigurationUsesRealCLIValidationAndPreservesInvalidSave() async throws {
        let path = directory.appendingPathComponent("cluster.json").path
        var worker = ClusterNodeConfiguration(id: "worker", sshDestination: "user@worker.local",
            stateDirectory: "/Users/user/Library/Application Support/MetalSandbox/native", maxConcurrentInstances: 3)
        worker.schedulingPool = "M2 Pro"; worker.crossNodeSchedulingEnabled = false
        var document = ClusterConfigurationDocument(localNodeID: "manager", sharedRoot: "/Users/Shared/metal_cluster", nodes: [worker], maxConcurrentInstances: 4)
        document.schedulingPool = "M3 Max"; document.crossNodeSchedulingEnabled = true
        try await client.saveClusterConfiguration(document, at: path)
        let loaded = try await client.readClusterConfiguration(at: path)
        XCTAssertEqual(loaded, document)
        let saved = try Data(contentsOf: URL(fileURLWithPath: path))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        for invalid in [
            ClusterConfigurationDocument(localNodeID: "worker", nodes: [worker]),
            ClusterConfigurationDocument(localNodeID: "manager", nodes: [worker, worker]),
            ClusterConfigurationDocument(localNodeID: "manager", sharedRoot: "relative/path", nodes: [worker]),
            ClusterConfigurationDocument(localNodeID: "manager", nodes: [worker], maxConcurrentInstances: -1),
            ClusterConfigurationDocument(localNodeID: "manager", nodes: [.init(id: "worker", sshDestination: "worker", stateDirectory: "/Users/user/state", maxConcurrentInstances: -1)]),
            ClusterConfigurationDocument(localNodeID: "manager", nodes: [.init(id: "worker", sshDestination: "-oProxyCommand=anything", stateDirectory: "/Users/user/state")])
        ] {
            do { try await client.saveClusterConfiguration(invalid, at: path); XCTFail("invalid cluster configuration accepted") }
            catch { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), saved) }
        }
        for name in ["", " invalid", "invalid\npool", String(repeating: "x", count: 65)] {
            var invalid = document; invalid.schedulingPool = name
            do { try await client.saveClusterConfiguration(invalid, at: path); XCTFail("invalid pool accepted") }
            catch { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), saved) }
        }
        let standaloneWorker = ClusterConfigurationDocument(localNodeID: "worker", sharedRoot: document.sharedRoot, maxConcurrentInstances: 0)
        try await client.saveClusterConfiguration(standaloneWorker, at: path)
        let workerLoaded = try await client.readClusterConfiguration(at: path)
        XCTAssertEqual(workerLoaded, standaloneWorker)
        let config = CLIConfiguration(directory: client.configuration.directory, stateDirectory: client.configuration.stateDirectory, clusterConfig: path)
        XCTAssertEqual(Array(config.serviceArguments.suffix(2)), ["--cluster-config", path])
        let standalone = CLIConfiguration(directory: client.configuration.directory, stateDirectory: client.configuration.stateDirectory, maxConcurrentInstances: 64)
        XCTAssertEqual(Array(standalone.serviceArguments.suffix(2)), ["--max-instances", "64"])
        try Data("{invalid".utf8).write(to: URL(fileURLWithPath: path))
        do { _ = try await client.readClusterConfiguration(at: path); XCTFail("invalid JSON accepted") }
        catch {}
    }

    func testSavedConfigurationDoesNotChangeRunningRoleOrStopActiveInstances() async throws {
        XCTAssertEqual(model.nodeRoleTitle, ui("单机", "Standalone"))
        let path = directory.appendingPathComponent("worker.json").path
        try await client.saveClusterConfiguration(.init(localNodeID: "worker", maxConcurrentInstances: 32), at: path)
        model.clusterConfig = path
        await model.refresh()
        XCTAssertTrue(model.serviceSettingsPending)
        XCTAssertEqual(model.nodeRoleTitle, ui("单机", "Standalone"))
        let applied = try await model.applySavedServiceSettings()
        XCTAssertFalse(applied)
        let refused = try await client.sandbox(["shutdown", "--if-idle"])
        XCTAssertNotEqual(refused.code, 0)
        XCTAssertTrue(refused.errorText.contains("local instances"))
        let live = try await client.sandbox(["inspect", instanceID]).reply().instance
        XCTAssertTrue(try XCTUnwrap(live).isActive)
        let before = try await client.sandbox(["status"]).reply().serviceProcessID
        _ = try await client.sandbox(["stop", instanceID]).checked()
        let changed = try await model.applySavedServiceSettings()
        XCTAssertTrue(changed)
        let worker = try await client.sandbox(["cluster"]).reply().cluster
        XCTAssertEqual(worker?.localNodeID, "worker")
        let after = try await client.sandbox(["status"]).reply().serviceProcessID
        XCTAssertNotEqual(before, after)
        model.clusterConfig = ""
        let restored = try await model.applySavedServiceSettings()
        XCTAssertTrue(restored)
        let standalone = try await client.sandbox(["cluster"]).reply().cluster
        XCTAssertNil(standalone)
    }

    func testPoolScopedCreationThroughPublicCLI() async throws {
        _ = try await client.sandbox(["stop", instanceID]).checked()
        let path = directory.appendingPathComponent("pool.json").path
        var document = ClusterConfigurationDocument(localNodeID: "pool_node", nodes: [], maxConcurrentInstances: 32)
        document.schedulingPool = "M3 Max"; document.crossNodeSchedulingEnabled = false
        try await client.saveClusterConfiguration(document, at: path)
        model.clusterConfig = path
        var createdID: String?
        func restore() async throws {
            if let createdID {
                _ = try await client.sandbox(["stop", createdID]).checked()
                _ = try await client.sandbox(["delete", createdID, "--confirm"]).checked()
            }
            model.clusterConfig = ""
            _ = try await model.applySavedServiceSettings()
        }
        do {
            _ = try await model.applySavedServiceSettings()
            let reply = try await client.sandbox(["create", "--count", "1", "--pool", "M3 Max", "--no_network"]).reply()
            let instance = try XCTUnwrap(reply.instances?.first)
            createdID = instance.id
            XCTAssertEqual(instance.nodeID, "pool_node")
            let missing = try await client.sandbox(["create", "--count", "1", "--pool", "unknown", "--no_network"])
            XCTAssertNotEqual(missing.code, 0)
            let mismatch = try await client.sandbox(["create", "--count", "1", "--pool", "M3 Max", "--node", "missing", "--no_network"])
            XCTAssertNotEqual(mismatch.code, 0)
            let snapshot = try await client.sandbox(["status"]).reply().status
            XCTAssertEqual(snapshot?.clusterNodes?.first?.pool, "M3 Max")
            XCTAssertEqual(snapshot?.clusterNodes?.first?.crossNodeSchedulingEnabled, false)
        } catch {
            try await restore()
            throw error
        }
        try await restore()
    }

    func testPreparationAndEnvironmentPreserveDirtyDrafts() async throws {
        let prep = model.preparation(for: instanceID), env = model.environment(for: instanceID)
        await prep.reload(app: model); await env.reload(app: model)
        XCTAssertNil(prep.error); XCTAssertNil(env.error)
        XCTAssertEqual(prep.files.script, "original")
        XCTAssertEqual(env.saved, ["TEST":"original"])
        prep.files.script = "draft"; env.rows = [EnvironmentRow(key:"TEST", value:"draft")]
        prep.verificationTimeoutText = "999"
        try await write("setup.sh", "changed")
        try await client.replaceEnvironment(id: instanceID, values: ["TEST":"changed"])
        _ = try await client.sandbox(["verification", instanceID, "--timeout", "123"]).checked()
        await prep.reload(app: model, preservingDraft:true)
        await env.reload(app: model, preservingDraft:true)
        XCTAssertNil(prep.error); XCTAssertNil(env.error)
        XCTAssertEqual(prep.files.script, "draft"); XCTAssertEqual(prep.saved.script, "changed")
        XCTAssertEqual(prep.verificationTimeoutText, "999")
        XCTAssertEqual(try EnvironmentDocument.values(env.rows), ["TEST":"draft"])
        XCTAssertEqual(env.saved, ["TEST":"changed"])
        await prep.reload(app: model); await env.reload(app: model)
        XCTAssertEqual(prep.files.script, "changed")
        XCTAssertEqual(prep.verificationTimeoutText, "123.0")
        XCTAssertFalse(prep.dirty); XCTAssertFalse(env.dirty)
        let rowIDs = env.rows.map(\.id)
        await env.reload(app: model, preservingDraft:true)
        XCTAssertEqual(env.rows.map(\.id), rowIDs)
    }

    func testDraftReloadCoalescingAndConnectionChange() async throws {
        let prep = model.preparation(for: instanceID)
        await prep.reload(app: model)
        XCTAssertNil(prep.error)
        let first = Task { await prep.reload(app: model, preservingDraft:true) }
        while !prep.loading { await Task.yield() }
        prep.files.script = "keep"
        await prep.reload(app: model, preservingDraft:true)
        await first.value
        XCTAssertEqual(prep.files.script, "keep")
        XCTAssertFalse(prep.loading); XCTAssertNil(prep.pendingReload)
        let old = prep.saved, state = model.stateDirectory
        try await write("setup.sh", "changed")
        let stale = Task { await prep.reload(app: model) }
        while !prep.loading { await Task.yield() }
        model.stateDirectory += "_changed"
        await stale.value
        model.stateDirectory = state
        XCTAssertEqual(prep.saved, old); XCTAssertEqual(prep.files.script, "keep")
        XCTAssertFalse(prep.loading)
    }

    func testHistoryPagingCoalescesAndDoesNotRepublish() async throws {
        var ids = Set<String>()
        for index in 0..<101 {
            let id = try await client.submit(id: instanceID, argv: ["/bin/echo", String(index)], cwd: ".", timeout: 10)
            _ = try await client.sandbox(["wait", id]).checked(); ids.insert(id)
        }
        var changes = 0
        let reader = ExecutionHistoryReader(configuration:model.configuration, instanceID:instanceID) { _ in changes += 1 }
        await reader.refresh()
        XCTAssertNil(reader.snapshot.error); XCTAssertEqual(reader.snapshot.records.count, 100)
        XCTAssertNotNil(reader.snapshot.cursor)
        let initial = changes
        await reader.refresh(); XCTAssertEqual(changes, initial)
        let current = Task { await reader.refresh() }
        await Task.yield()
        await reader.refresh(more:true); await current.value
        XCTAssertEqual(Set(reader.snapshot.records.map(\.id)), ids)
        XCTAssertNil(reader.snapshot.cursor); XCTAssertFalse(reader.snapshot.loadingMore)
    }

    func testVerificationRefreshKeepsSelectionAndDoesNotPublishUnchangedData() async throws {
        let first = try await verify()
        let session = model.verification(for: instanceID)
        await session.refresh()
        XCTAssertNil(session.error); XCTAssertEqual(session.selectedID, first)
        var changes = 0
        let subscription = session.objectWillChange.sink { changes += 1 }
        for _ in 0..<3 { await session.refresh() }
        XCTAssertEqual(changes, 0)
        _ = try await verify(); await session.refresh()
        XCTAssertEqual(session.selectedID, first); XCTAssertEqual(session.records.count, 2)
        withExtendedLifetime(subscription) {}
    }

    func testReloadFailureAndCancellationDoNotLoseDrafts() async throws {
        let env = model.environment(for:instanceID)
        await env.reload(app:model); XCTAssertNil(env.error)
        env.rows = [EnvironmentRow(key:"TEST", value:"draft")]
        try await client.replaceEnvironment(id:instanceID, values:["TEST":"not-applied"])
        let read = Task { await env.reload(app:model) }
        while !env.loading { await Task.yield() }
        read.cancel(); await read.value
        XCTAssertEqual(env.saved, ["TEST":"original"])
        XCTAssertEqual(try EnvironmentDocument.values(env.rows), ["TEST":"draft"])
        XCTAssertFalse(env.loading); XCTAssertNil(env.pendingReload)
        _ = try await client.sandbox(["stop", instanceID]).checked()
        _ = try await client.sandbox(["delete", instanceID, "--confirm"]).checked()
        await env.reload(app:model, preservingDraft:true)
        XCTAssertNotNil(env.error); XCTAssertFalse(env.loading)
        XCTAssertEqual(try EnvironmentDocument.values(env.rows), ["TEST":"draft"])
    }

    func testVerificationRecoversFromReadErrors() async throws {
        let id = try await verify(), session = model.verification(for:instanceID)
        await session.refresh(); XCTAssertNil(session.error)
        session.selectedID = UUID().uuidString.lowercased()
        await session.readSelected(); XCTAssertNotNil(session.error)
        session.selectedID = id
        await session.refresh()
        XCTAssertNil(session.error); XCTAssertEqual(session.selectedID, id)
    }

    func testCounterDistributionRefreshesWithoutChangingTotal() async throws {
        _ = try await client.submit(id:instanceID, argv:["/bin/sleep", "60"], cwd:".", timeout:90)
        let queued = try await client.submit(id:instanceID, argv:["/bin/sleep", "60"], cwd:".", timeout:90)
        try await waitForCounts(serialRunning:1, serialWaiting:1, parallelRunning:0)
        await model.refresh(); XCTAssertEqual(model.status?.pendingExecutions, 2)
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        _ = try await client.sandbox(["cancel", queued]).checked()
        _ = try await client.sandbox(["wait", queued])
        _ = try await client.submit(id:instanceID, argv:["/bin/sleep", "30"], cwd:".", timeout:60)
        try await waitForCounts(serialRunning:1, serialWaiting:0, parallelRunning:1)
        await model.refresh()
        XCTAssertEqual(model.status?.pendingExecutions, 2)
        XCTAssertEqual(model.status?.executionCounts?.parallelRunning, 1)
        XCTAssertEqual(model.instances.first { $0.id == instanceID }?.executionCounts?.serialWaiting, 0)
        XCTAssertGreaterThan(changes, 0)
        changes = 0; await model.refresh(); XCTAssertEqual(changes, 0)
        withExtendedLifetime(subscription) {}
    }

    func testOverviewWithMultiDigitCounters() throws {
        let overview = OverviewView(showCreate:.constant(false), startConfirmation:.constant(false), showRecovery:.constant(false))
        for (width, total, pr, pw, sw) in [(280.0, 128, 64, 0, 63), (460.0, 123456, 99999, 2345, 21111)] {
            let data = try JSONSerialization.data(withJSONObject: ["parallelRunning":pr,"parallelWaiting":pw,"serialRunning":1,"serialWaiting":sw])
            let counts = try JSONDecoder().decode(ExecutionCounts.self, from:data)
            let content = overview.metricValues(String(total), counts:counts, showCounts:true)
                .frame(width:width, height:64).padding(16)
                .background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,.light)
            let renderer = ImageRenderer(content:content); renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, Int((width + 32) * 2))
            if let output = ProcessInfo.processInfo.environment["METAL_SANDBOX_UI_TEST_SNAPSHOTS"] {
                let folder = URL(fileURLWithPath:output)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]))
                try png.write(to:folder.appendingPathComponent("metric_\(Int(width)).png"))
            }
        }
    }
}
