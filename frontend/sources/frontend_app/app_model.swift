import AppKit
import SwiftUI
import FrontendCore

struct OperationResult {
    let text: String
    let reveal: DeletedContainerReveal
    let configuration: CLIConfiguration
    let sandboxIDs: [String]
}

@MainActor final class NodeUtilizationMonitor: ObservableObject {
    @Published private(set) var value: HostUtilization?
    init(_ value: HostUtilization? = nil) { self.value = value }
    func update(_ value: HostUtilization?) {
        if self.value != value { self.value = value }
    }
}

private extension ServiceStatus {
    func withoutUtilization() -> ServiceStatus {
        var result = self
        result.host.utilization = nil
        result.clusterNodes = clusterNodes?.map { node in
            var node = node
            node.status = node.status?.withoutUtilization()
            node.lastKnownStatus = node.lastKnownStatus?.withoutUtilization()
            return node
        }
        return result
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var language = InterfaceLanguage.current {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: InterfaceLanguage.preferenceKey) }
    }
    @Published var page: Page? = .overview
    @Published var instances: [SandboxInstance] = []
    @Published var status: ServiceStatus?
    @Published private(set) var runningCluster: ClusterConfigurationDocument?
    @Published private(set) var serviceSettingsPending = false
    @Published var cliVersion = ""
    @Published var connectionError = ""
    @Published var alert: String?
    @Published var batchResult: OperationResult?
    @Published var busy = false
    private var refreshing = false
    private var refreshPending = false
    @Published var activities: [Activity] = []
    @Published var historyError: String?
    @Published private(set) var historyLoadingMore = false
    @Published var historyCursor: String?
    private var historyReader: ExecutionHistoryReader?
    private var readingExecutions: Set<String> = []
    @Published var activityFilter: ActivityFilter = .all
    @Published var directory: String
    @Published var stateDirectory: String
    @Published var clusterConfig: String
    @Published var refreshSeconds: Double
    @Published var maxConcurrentInstances: Int
    private var serviceProcess: Process?
    private var utilizationMonitors: [String: NodeUtilizationMonitor] = [:]
    func utilization(for nodeID: String? = nil) -> NodeUtilizationMonitor {
        let key = nodeID ?? "$local"
        if let monitor = utilizationMonitors[key] { return monitor }
        let monitor = NodeUtilizationMonitor()
        utilizationMonitors[key] = monitor
        return monitor
    }
    private var terminals: [String: TerminalSession] = [:]
    private var workspaces: [String: WorkspaceBrowser] = [:]
    private var trajectories: [String: TrajectoryBrowser] = [:]
    func trajectory(for id: String) -> TrajectoryBrowser {
        if let value = trajectories[id] { return value }
        let value = TrajectoryBrowser(instanceID: id, configuration: configuration); trajectories[id] = value; return value
    }
    private var environments: [String: EnvironmentSession] = [:]
    func environment(for id: String) -> EnvironmentSession {
        if let value = environments[id] { return value }
        let value = EnvironmentSession(id: id, configuration: configuration); environments[id] = value; return value
    }
    private var preparations: [String: PreparationSession] = [:]
    private var verifications: [String: VerificationSession] = [:]
    func verification(for id: String) -> VerificationSession {
        if let value = verifications[id] { return value }
        let value = VerificationSession(instanceID: id, configuration: configuration); verifications[id] = value; return value
    }
    func preparation(for id: String) -> PreparationSession {
        if let value = preparations[id] { return value }
        let value = PreparationSession(instanceID: id, configuration: configuration); preparations[id] = value; return value
    }
    func workspace(for id: String) -> WorkspaceBrowser {
        if let value = workspaces[id] { return value }
        let value = WorkspaceBrowser(instanceID: id, configuration: configuration); workspaces[id] = value; return value
    }
    func terminal(for id: String) -> TerminalSession {
        if let value = terminals[id] { return value }
        let value = TerminalSession(instanceID: id); terminals[id] = value; return value
    }
    func closeTerminals() { terminals.values.forEach { $0.disconnect() }; terminals = [:] }
    func closeWorkspacePreviews() { workspaces.values.forEach { $0.closePreview() } }

    init() {
        let defaults = UserDefaults.standard
        directory = defaults.string(forKey: "cli_directory") ?? ""
        stateDirectory = defaults.string(forKey: "state_directory") ?? NSHomeDirectory() + "/Library/Application Support/MetalSandbox/native"
        clusterConfig = defaults.string(forKey: "cluster_config") ?? ""
        refreshSeconds = defaults.object(forKey: "refresh_seconds") as? Double ?? 5
        maxConcurrentInstances = defaults.object(forKey: "max_concurrent_instances") as? Int ?? 32
    }
    var bundledDirectory: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers") }
    var configuration: CLIConfiguration {
        CLIConfiguration(directory: directory.isEmpty ? bundledDirectory : URL(fileURLWithPath: directory), stateDirectory: stateDirectory, clusterConfig: clusterConfig.isEmpty ? nil : clusterConfig,
            maxConcurrentInstances: clusterConfig.isEmpty ? maxConcurrentInstances : nil)
    }
    var client: CLIClient { CLIClient(configuration) }
    var nodeRoleTitle: String {
        if let runningCluster { return runningCluster.nodes.isEmpty ? ui("从节点", "Worker Node") : ui("管理节点", "Manager Node") }
        return status?.nodeID == nil ? ui("单机", "Standalone") : ui("读取中", "Loading")
    }
    var canApplyServiceSettings: Bool {
        canMutate && status?.activeInstances == 0 && status?.pendingExecutions == 0
    }
    var compatible: Bool { status?.protocolVersion == 1 && status?.serviceVersion == cliVersion && !cliVersion.isEmpty }
    var canMutate: Bool { compatible && !busy }
    var canCreate: Bool {
        guard canMutate else { return false }
        if let nodes = status?.clusterNodes, !nodes.isEmpty {
            return nodes.contains { $0.status.map { $0.recoveryReason == nil && !$0.isThermallyPaused && $0.activeInstances < ($0.maxConcurrentInstances ?? 32) } ?? false }
        }
        return status.map { $0.recoveryReason == nil && $0.activeInstances < ($0.maxConcurrentInstances ?? 32) } ?? false
    }
    func filesAvailable(_ instance: SandboxInstance) -> Bool {
        compatible && instance.hasWorkspace && (instance.isActive || status?.stoppedFileAccessImplemented == true)
    }
    func revealWorkspace(_ id: String, path: String, configuration: CLIConfiguration) {
        perform {
            try await self.command(["reveal-file", id, path], title: ui("在访达中显示工作区条目", "Reveal Workspace Item in Finder"), client: CLIClient(configuration), sandboxIDs: [id])
        }
    }
    var selected: SandboxInstance? { if case .sandbox(let id) = page { return instances.first { $0.id == id } }; return nil }

    func saveSettings() {
        historyReader = nil; historyCursor = nil; historyError = nil; historyLoadingMore = false
        closeTerminals()
        closeWorkspacePreviews()
        workspaces = [:]
        preparations = [:]
        verifications = [:]
        environments = [:]
        trajectories = [:]
        utilizationMonitors = [:]
        UserDefaults.standard.set(directory, forKey: "cli_directory")
        UserDefaults.standard.set(stateDirectory, forKey: "state_directory")
        UserDefaults.standard.set(clusterConfig, forKey: "cluster_config")
        UserDefaults.standard.set(refreshSeconds, forKey: "refresh_seconds")
        UserDefaults.standard.set(maxConcurrentInstances, forKey: "max_concurrent_instances")
        status = nil; runningCluster = nil; serviceSettingsPending = false; cliVersion = ""; instances = []
        Task { await refresh() }
    }
    func refresh() async {
        guard !refreshing else { refreshPending = true; return }
        refreshing = true
        defer {
            refreshing = false
            if refreshPending { refreshPending = false; Task { await self.refresh() } }
        }
        let current = configuration, client = CLIClient(configuration)
        var receivedStatus = false
        do {
            let version = try await client.run(.sandbox, ["--version"], timeout: 10).checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = try await client.sandbox(["status"], timeout: 10).reply()
            guard let fresh = reply.status else { throw CLIError(ui("status 未返回服务信息", "status did not return service information")) }
            guard current == configuration else { return }
            // Publishing identical snapshots invalidates unrelated native UI,
            // including toolbar hover/help state. Only publish real changes.
            if cliVersion != version { cliVersion = version }
            utilization().update(fresh.host.utilization)
            for node in fresh.clusterNodes ?? [] where node.id != fresh.nodeID {
                utilization(for: node.id).update(node.status?.host.utilization)
            }
            let viewStatus = fresh.withoutUtilization()
            if status != viewStatus { status = viewStatus }
            receivedStatus = true
            let running = try await client.sandbox(["cluster"], timeout: 10).reply().cluster
            let desired: ClusterConfigurationDocument?
            if let path = current.clusterConfig { desired = try await client.readClusterConfiguration(at: path) }
            else { desired = nil }
            guard current == configuration else { return }
            if runningCluster != running { runningCluster = running }
            let pending = running != desired || (desired == nil && (fresh.maxConcurrentInstances ?? 32) != (current.maxConcurrentInstances ?? 32))
            if serviceSettingsPending != pending { serviceSettingsPending = pending }
            let list = try await client.sandbox(["list"], timeout: 15).reply()
            guard current == configuration else { return }
            let freshInstances = (list.instances ?? []).sorted { $0.createdAt > $1.createdAt }
            if instances != freshInstances { instances = freshInstances }
            for (id, terminal) in terminals where !instances.contains(where: { $0.id == id && $0.isActive }) { terminal.disconnect() }
            terminals = terminals.filter { id, _ in instances.contains { $0.id == id } }
            workspaces = workspaces.filter { id, _ in instances.contains { $0.id == id } }
            trajectories = trajectories.filter { id, _ in instances.contains { $0.id == id } }
            environments = environments.filter { id, _ in instances.contains { $0.id == id } }
            preparations = preparations.filter { id, _ in instances.contains { $0.id == id } }
            verifications = verifications.filter { id, _ in instances.contains { $0.id == id } }
            let message = compatible ? "" : ui("CLI 与服务版本不一致。请关闭管理服务，再使用同一套程序启动。", "CLI and service versions differ. Shut down the manager, then start it using matching tools.")
            if connectionError != message { connectionError = message }
            if compatible && fresh.executionHistoryImplemented == true { await refreshHistory() }
        } catch {
            guard current == configuration else { return }
            if !receivedStatus {
                if status != nil { status = nil }
                if runningCluster != nil { runningCluster = nil }
                if serviceSettingsPending { serviceSettingsPending = false }
                if !instances.isEmpty { instances = [] }
            }
            if connectionError != error.localizedDescription { connectionError = error.localizedDescription }
        }
    }

    func refreshHistory(more: Bool = false) async {
        guard status?.executionHistoryImplemented == true else { return }
        if historyReader == nil {
            let current = configuration
            historyReader = ExecutionHistoryReader(configuration: current) { [weak self] snapshot in
                guard let self, current == self.configuration else { return }
                var merged = self.activities
                Activity.merge(snapshot.records, into: &merged, configuration: current)
                if self.activities != merged { self.activities = merged }
                if self.historyCursor != snapshot.cursor { self.historyCursor = snapshot.cursor }
                if self.historyError != snapshot.error { self.historyError = snapshot.error }
                if self.historyLoadingMore != snapshot.loadingMore { self.historyLoadingMore = snapshot.loadingMore }
            }
        }
        await historyReader?.refresh(more: more)
    }
    func readExecution(_ activity: Activity) async {
        guard let id = activity.executionID, let config = activity.configuration, !readingExecutions.contains(id) else { return }
        readingExecutions.insert(id); defer { readingExecutions.remove(id) }
        do {
            guard let detail = try await CLIClient(config).sandbox(["execution", id]).reply().execution else { throw CLIError(ui("未返回执行详情", "No execution details returned")) }
            update(activity.id) { item in
                item.backendState = detail.state; item.waiting = ["queued", "running"].contains(detail.state)
                if let target = detail.instanceID { item.sandboxIDs = [target] }
                if let command = detail.command {
                    item.command = "sandboxctl " + CommandInput.display(config.sandbox(["exec", detail.instanceID ?? "", "--cwd", command.cwd, "--timeout", String(command.timeoutSeconds)] + (command.agentSession == true ? ["--session"] : []) + ["--"] + command.argv))
                    item.hasCommandDetails = true
                }
                if let result = detail.result {
                    item.output = String(decoding: result.stdout, as: UTF8.self)
                    item.error = String(decoding: result.stderr, as: UTF8.self)
                    item.code = result.outcome.exitCode
                } else { item.error = "" }
                if let error = detail.error { item.error += (item.error.isEmpty ? "" : "\n") + error }
            }
        } catch { historyError = error.localizedDescription }
    }

    func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { alert = error.localizedDescription }
            await refresh()
        }
    }
    func log(_ item: Activity) -> UUID {
        if activities.filter({ $0.backendState == nil }).count >= 100, let index = activities.lastIndex(where: { $0.backendState == nil && !$0.waiting && $0.code != nil }) { activities.remove(at: index) }
        activities.insert(item, at: 0); return item.id
    }
    func update(_ id: UUID, _ edit: (inout Activity) -> Void) {
        if let index = activities.firstIndex(where: { $0.id == id }) {
            var updated = activities[index]; edit(&updated)
            if activities[index] != updated { activities[index] = updated }
        }
    }
    @discardableResult func command(_ args: [String], title: String, client override: CLIClient? = nil, sandboxIDs: [String] = []) async throws -> CLIOutput {
        let client = override ?? client
        let targets = Array(Set(sandboxIDs + Activity.targets(args))).sorted()
        let id = log(Activity(title: title, command: "sandboxctl " + CommandInput.display(client.configuration.sandbox(args)), sandboxIDs: targets, configuration: client.configuration))
        do {
            let output = try await client.sandbox(args)
            let resolvedTargets = Activity.targets(args, reply: try? output.reply())
            update(id) {
                $0.output = output.text; $0.error = output.errorText; $0.code = output.code
                $0.sandboxIDs = Array(Set(targets + resolvedTargets)).sorted()
            }
            return try output.checked()
        } catch {
            update(id) { $0.error = error.localizedDescription; $0.code = 1 }
            throw error
        }
    }
    func create(_ count: Int, name: String = "", networkClient: Bool = true, taskPolicyJSON: String? = nil, preparationScript: String = "", preparationTimeout: Double = 3600, taskPackage: URL? = nil, environment: [String: String] = [:], autoVerify: Bool = true, verificationTimeout: Double = 600, nodeID: String? = nil, schedulingPool: String? = nil, dynamicScheduling: Bool = false) {
        let current = client
        perform {
            if let taskPackage { _ = try PreparationFiles.script(inTaskPackage: taskPackage) }
            _ = try EnvironmentDocument.values(EnvironmentDocument.rows(environment))
            var args = ["create", "--count", String(count), "--name", name] + (networkClient ? [] : ["--no_network"])
            if let nodeID { args += ["--node", nodeID] }
            if let schedulingPool { args += ["--pool", schedulingPool] }
            if dynamicScheduling { args.append("--dynamic-scheduling") }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("metal_sandbox_ui_policy_" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: scratch) }
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            if let taskPolicyJSON {
                let policy = try TaskPolicyDocument.parse(taskPolicyJSON)
                let file = scratch.appendingPathComponent("task_policy.json")
                try policy.json().write(to: file, atomically: true, encoding: .utf8)
                args += ["--task-policy", file.path]
            }
            if !environment.isEmpty {
                let file = scratch.appendingPathComponent("environment.json")
                try JSONEncoder().encode(environment).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                args += ["--env-file", file.path]
            }
            let reply = try await self.command(args, title: ui("创建 \(count) 个 sandbox", "Create \(count) sandboxes"), client: current).reply()
            for instance in reply.instances ?? [] {
                self.preparation(for: instance.id).timeoutText = String(preparationTimeout)
            }
            if let first = reply.instances?.first { self.page = .sandbox(first.id) }
            let importTask: ((String) async throws -> Void)? = taskPackage.map { folder in
                { id in
                    try await self.command(["import", id, "--from", folder.path, "--task"], title: ui("导入题包", "Import Task Package"), client: current)
                    guard let settings = try await current.sandbox(["verification", id]).reply().verificationSettings else { throw CLIError(ui("未返回自动验收配置", "No automatic verification settings returned")) }
                    if settings.testPackageSHA256 != nil {
                        _ = try await self.command(["verification", id, "--enabled", String(autoVerify), "--timeout", String(verificationTimeout)], title: ui("设置自动验收", "Set Automatic Verification"), client: current)
                    }
                }
            }
            let failures = await PreparationFiles.prepareReplicas(ids: reply.instances?.map(\.id) ?? [], script: preparationScript, importTask: importTask) { id, script in
                try await self.writeText(id, path: "setup.sh", text: script, client: current)
                try await self.submit(id, argv: ["/bin/sh", "./setup.sh"], timeout: preparationTimeout, session: true, client: current)
            }
            if !failures.isEmpty {
                throw CLIError(ui("实例已创建；以下实例的题包导入或准备提交未完成：\n", "Instances were created; task import or preparation submission did not finish for:\n") + failures.joined(separator: "\n") + ui("\n其他实例已继续处理。不会自动重试或删除实例。", "\nOther instances were processed. No instances are automatically retried or deleted."))
            }
        }
    }
    func inspect(_ id: String) async throws {
        let current = configuration
        let reply = try await command(["inspect", id], title: ui("刷新实例详情", "Refresh Instance Details"), client: CLIClient(current)).reply()
        guard current == configuration, !Task.isCancelled else { return }
        if let value = reply.instance, let i = instances.firstIndex(where: { $0.id == id }), instances[i] != value { instances[i] = value }
    }
    func rename(_ id: String, name: String) {
        let current = client
        perform {
            let reply = try await self.command(["rename", id, name], title: ui("重命名实例", "Rename Instance"), client: current).reply()
            if let value = reply.instance, let index = self.instances.firstIndex(where: { $0.id == id }) {
                self.instances[index] = value
            }
        }
    }
    func stop(_ id: String) { perform { try await self.command(["stop", id], title: ui("停止实例", "Stop Instance")) } }
    func start(_ id: String) {
        perform {
            try await self.command(["start", id], title: ui("启动原实例", "Start Original Instance"))
            self.terminals.removeValue(forKey: id)?.disconnect()
            self.workspaces.removeValue(forKey: id)
        }
    }
    func openTerminal(_ id: String) {
        let current = client
        perform {
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw CLIError(ui("找不到 macOS 终端应用。", "Cannot find the macOS Terminal application."))
            }
            let launcher = try current.terminalLauncher(id)
            do {
                _ = try await NSWorkspace.shared.open([launcher], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                try? FileManager.default.removeItem(at: launcher.deletingLastPathComponent())
                throw error
            }
        }
    }
    func revealContainers(_ selected: [SandboxInstance]) {
        let bundleIDs = selected.containerBundleIDs
        guard !bundleIDs.isEmpty else { return }
        let skipped = selected.filter { $0.physical?.bundleID == nil }.map(\.id)
        let current = client
        perform {
            let reply = try await self.command(["reveal-containers"] + bundleIDs, title: ui("在访达中显示容器", "Reveal Containers in Finder"), client: current, sandboxIDs: selected.map(\.id)).reply()
            let warnings = (reply.warnings ?? []) + (skipped.isEmpty ? [] : [ui("以下实例尚无物理容器，已跳过：\n", "Skipped instances without physical containers:\n") + skipped.joined(separator: "\n")])
            if !warnings.isEmpty { self.alert = warnings.joined(separator: "\n") }
        }
    }
    func delete(_ id: String) {
        let current = client
        perform {
            let reply = try await self.command(["delete", id, "--confirm"], title: ui("删除实例", "Delete Instance"), client: current).reply()
            self.page = .overview
            if let warnings = reply.warnings, !warnings.isEmpty {
                self.batchResult = OperationResult(text: ui("实例的已确认数据已删除。\n\n", "Confirmed instance data was deleted.\n\n") + warnings.joined(separator: "\n"),
                    reveal: DeletedContainerReveal(replies: [reply]), configuration: current.configuration, sandboxIDs: [id])
            }
        }
    }
    func batchBlockingReason(_ batch: SandboxBatch, configuration expected: CLIConfiguration) -> String? {
        guard expected == configuration else { return ui("连接设置已改变，请重新选择实例。", "Connection settings changed; select the instances again.") }
        guard compatible else { return ui("请先连接兼容服务。", "Connect to a compatible service first.") }
        return batch.blockingReason(instances: instances, status: status)
    }
    func runBatch(_ batch: SandboxBatch, configuration expected: CLIConfiguration) {
        guard canMutate else { return }
        let fixedClient = CLIClient(expected)
        perform {
            // Recheck the frozen target set; the backend remains authoritative
            // if a target changes after this check.
            await self.refresh()
            if let reason = self.batchBlockingReason(batch, configuration: expected) { throw CLIError(reason) }
            var warnings: [String] = []
            var replies: [CLIReply] = []
            let result = await batch.execute { id, args in
                let reply = try await self.command(args, title: ui("批量\(batch.action.title) · \(id)", "Batch \(batch.action.title) · \(id)"), client: fixedClient).reply()
                replies.append(reply)
                warnings += (reply.warnings ?? []).map { id + ": " + $0 }
            }
            if batch.action == .delete, case .sandbox(let id) = self.page, result.completed.contains(id) { self.page = .overview }
            let text = (warnings.isEmpty ? result.summary(action: batch.action) : result.summary(action: batch.action).replacingOccurrences(of: ui("已永久删除", "Permanently deleted"), with: ui("已移除实例并删除已确认数据：", "Removed instances and deleted confirmed data:"))) + (warnings.isEmpty ? "" : ui("\n\n未删除的残留：\n", "\n\nUndeleted leftovers:\n") + warnings.joined(separator: "\n"))
            self.batchResult = OperationResult(text: text, reveal: DeletedContainerReveal(replies: replies), configuration: expected, sandboxIDs: replies.compactMap { $0.instance?.id })
        }
    }
    func restore(_ id: String) {
        perform {
            let reply = try await self.command(["restore", id], title: ui("从快照克隆", "Clone from Snapshot")).reply()
            if let new = reply.instance { self.page = .sandbox(new.id) }
        }
    }
    func shutdown() { perform { try await self.command(["shutdown"], title: ui("关闭管理服务", "Shut Down Manager")) } }
    func stopAll() {
        // stop --all emits multiple JSON documents; do not parse as one reply.
        perform { try await self.command(["stop", "--all"], title: ui("停止全部实例", "Stop All Instances")) }
    }
    func recover(_ note: String) {
        perform { try await self.command(["recover", "--confirm-processes-cleaned", "--note", note], title: ui("人工确认恢复节点", "Confirm Node Recovery")) }
    }
    func startService() {
        perform { try await self.startServiceAndWait() }
    }
    func applyServiceSettings() {
        Task {
            do {
                if !(try await applySavedServiceSettings()) { alert = ui("当前有活动实例或待完成命令，配置尚未应用。", "Configuration has not been applied because instances or commands are active.") }
            } catch { alert = error.localizedDescription }
        }
    }
    func applySavedServiceSettings() async throws -> Bool {
        guard !busy else { throw CLIError(ui("请等待当前操作完成。", "Wait for the current operation to finish.")) }
        busy = true
        defer { busy = false; Task { await refresh() } }
        let current = client
        guard let fresh = try await current.sandbox(["status"], timeout: 10).reply().status else { throw CLIError(ui("服务未返回状态。", "The service did not return its status.")) }
        let running = try await current.sandbox(["cluster"], timeout: 10).reply().cluster
        let desired: ClusterConfigurationDocument?
        if let path = current.configuration.clusterConfig { desired = try await current.readClusterConfiguration(at: path) }
        else { desired = nil }
        let changed = running != desired || (desired == nil && (fresh.maxConcurrentInstances ?? 32) != (current.configuration.maxConcurrentInstances ?? 32))
        guard changed else { return true }
        guard fresh.activeInstances == 0, fresh.pendingExecutions == 0 else { return false }
        _ = try await command(["shutdown", "--if-idle"], title: ui("应用服务配置", "Apply Service Configuration"), client: current)
        try await startServiceAndWait()
        return true
    }
    func startServiceAndWait() async throws {
        let location = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("MetalSandboxUI/service_logs")
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let logURL = location.appendingPathComponent(UUID().uuidString.lowercased() + ".log")
        let current = self.client
        let id = self.log(Activity(title: ui("启动管理服务", "Start Manager Service"), command: "metal-sandboxd " + CommandInput.display(current.configuration.serviceArguments)))
        do {
            self.serviceProcess = try current.startService(log: logURL)
            for _ in 0..<50 {
                try await Task.sleep(nanoseconds: 200_000_000)
                if let service = self.serviceProcess, !service.isRunning {
                    let detail = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ui("服务启动失败", "Service startup failed")
                    throw CLIError(detail + ui("\n请确认 Command Line Tools 已安装，且同 UID 没有另一个服务。", "\nCheck that Command Line Tools are installed and that no other service is running under the same UID."))
                }
                if let reply = try? await current.sandbox(["status"], timeout: 2).reply(), reply.status != nil {
                    self.update(id) { $0.code = 0; $0.output = ui("服务已启动。关闭前端不会停止服务。\n启动日志：\(logURL.path)", "Service started. Closing the frontend does not stop it.\nStartup log: \(logURL.path)") }
                    return
                }
            }
            throw CLIError(ui("尚未确认服务就绪。不会重复启动；请刷新检查。日志：\(logURL.path)", "Service readiness is unconfirmed. It will not be started again; refresh to check. Log: \(logURL.path)"))
        } catch { self.update(id) { $0.code = 1; $0.error = error.localizedDescription }; throw error }
    }

    func submit(_ instanceID: String, argv: [String], cwd: String = ".", timeout: Double = 30, session: Bool = false, client: CLIClient? = nil) async throws {
        let current = client ?? self.client
        let shown = ["exec", instanceID, "--cwd", cwd, "--timeout", String(timeout), "--detach"] + (session ? ["--session"] : []) + ["--"] + argv
        let activityID = log(Activity(title: ui("执行 · \(argv.first ?? "")", "Run · \(argv.first ?? "")"), command: "sandboxctl " + CommandInput.display(current.configuration.sandbox(shown)), sandboxIDs: [instanceID], configuration: current.configuration))
        do {
            let executionID = try await current.submit(id: instanceID, argv: argv, cwd: cwd, timeout: timeout, session: session)
            observe(executionID, activityID: activityID, current: current)
        } catch {
            update(activityID) { $0.error = error.localizedDescription; $0.code = 1 }
            throw error
        }
    }
    func verify(_ instanceID: String, taskFolder: URL?, timeout: Double, configuration: CLIConfiguration) async throws -> String {
        guard configuration == self.configuration else { throw CLIError(ui("连接设置已改变，请重新打开验收页。", "Connection settings changed; reopen the verification page.")) }
        let current = CLIClient(configuration)
        let args = try Verification.arguments(id: instanceID, taskFolder: taskFolder, timeout: timeout)
        let activityID = log(Activity(title: ui("验收 · tests/test.sh", "Verify · tests/test.sh"), command: "sandboxctl " + CommandInput.display(configuration.sandbox(args)), sandboxIDs: [instanceID], configuration: configuration))
        do {
            let reply = try await current.sandbox(args, timeout: .greatestFiniteMagnitude).reply()
            guard let id = reply.execution?.id else { throw CLIError(ui("未返回验收执行 ID，请先刷新记录，不要重复提交。", "No verification execution ID returned. Refresh records before submitting again.")) }
            observe(id, activityID: activityID, current: current)
            return id
        } catch {
            update(activityID) { $0.error = error.localizedDescription; $0.code = 1 }
            throw error
        }
    }
    private func observe(_ executionID: String, activityID: UUID, current: CLIClient) {
        update(activityID) { $0.executionID = executionID; $0.waiting = true }
        Task {
            do {
                let output = try await current.sandbox(["wait", executionID])
                self.update(activityID) { $0.output = output.text; $0.error = output.errorText; $0.code = output.code; $0.waiting = false }
            } catch {
                self.update(activityID) { $0.error = error.localizedDescription; $0.code = 1; $0.waiting = false }
            }
            await self.refresh()
        }
    }
    func cancel(_ activity: Activity) {
        guard let id = activity.executionID, let config = activity.configuration else { return }
        perform { try await self.command(["cancel", id], title: ui("请求取消执行", "Request Execution Cancellation"), client: CLIClient(config), sandboxIDs: activity.sandboxIDs) }
    }
    func waitAgain(_ executionID: String) {
        let current = client
        if let existing = activities.first(where: { $0.executionID == executionID && $0.configuration == current.configuration }) {
            if !existing.waiting { observe(executionID, activityID: existing.id, current: current) }
            return
        }
        let targets = Activity.targets(executionID: executionID, configuration: current.configuration, in: activities)
        let id = log(Activity(title: ui("等待已有执行", "Wait for Existing Execution"), command: "sandboxctl " + CommandInput.display(current.configuration.sandbox(["wait", executionID])), executionID: executionID, sandboxIDs: targets, configuration: current.configuration, waiting: true))
        observe(executionID, activityID: id, current: current)
    }

    func writeText(_ instanceID: String, path: String, text: String, client: CLIClient? = nil) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("metal_sandbox_ui_input_" + UUID().uuidString)
        try Data(text.utf8).write(to: scratch, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.path)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await command(["write", instanceID, path, "--from", scratch.path], title: ui("写入 \(path)", "Write \(path)"), client: client)
    }
}
