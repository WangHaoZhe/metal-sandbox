import SwiftUI
import AppKit
import FrontendCore

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var selection: UUID?
    @ViewState private var executionID = ""
    private var filtered: [Activity] { model.activities.filter { model.activityFilter.includes($0) } }
    private var sandboxIDs: [String] {
        var ids = ActivityFilter.sandboxIDs(in: model.activities, currentIDs: model.instances.map(\.id))
        if case .sandbox(let id) = model.activityFilter, !ids.contains(id) { ids.append(id); ids.sort() }
        return ids
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: ui("操作记录", "Activity"), subtitle: ui("后端执行历史与当前前端操作；包含通过 CLI 提交的命令。命令结果不等于算法正确。", "Backend execution history and frontend operations, including commands submitted through the CLI. Command results do not establish algorithm correctness."))
            if let error = model.historyError { Note(text: error, warning: true) }
            Picker("Sandbox", selection: $model.activityFilter) {
                Text(ui("全部记录", "All Records")).tag(ActivityFilter.all)
                Text(ui("服务 / 未归属记录", "Service / Unassigned")).tag(ActivityFilter.unassigned)
                ForEach(sandboxIDs, id: \.self) { id in Text(id).tag(ActivityFilter.sandbox(id)) }
            }.pickerStyle(.menu).accessibilityLabel(ui("按 Sandbox ID 筛选", "Filter by Sandbox ID")).accessibilityIdentifier("activity_sandbox_filter")
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(ui("刷新记录", "Refresh Records")) { Task { await model.refreshHistory() } }
                if model.historyCursor != nil { Button(ui("加载更早的执行", "Load Earlier Executions")) { Task { await model.refreshHistory(more: true) } }.disabled(model.historyLoadingMore) }
                TextField(ui("已有执行 ID", "Existing Execution ID"), text: $executionID).textFieldStyle(.roundedBorder).accessibilityLabel(ui("已有执行 ID", "Existing Execution ID"))
                Button(ui("等待结果", "Wait for Results")) { model.waitAgain(executionID) }.accessibilityIdentifier("wait_execution").disabled(executionID.isEmpty || !model.canMutate)
            }
            VSplitView {
                List(filtered, selection: $selection) { item in
                    HStack {
                        Image(systemName: item.waiting ? "clock" : item.code == 0 ? "checkmark.circle" : item.code == nil ? "ellipsis.circle" : "exclamationmark.circle")
                            .foregroundStyle(item.code == 0 ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                            Text(item.sandboxIDs.isEmpty ? ui("服务 / 未归属记录", "Service / Unassigned") : item.sandboxIDs.joined(separator: ", "))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text(item.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Text(item.status).font(.caption).foregroundStyle(.secondary)
                    }.tag(item.id)
                }.frame(minHeight: 120, idealHeight: 220).accessibilityIdentifier("activity_list")
                if let item = filtered.first(where: { $0.id == selection }) ?? filtered.first { ActivityDetail(activity: item).id(item.id).frame(minHeight: 160).padding(.top, 12) }
                else { OutputView(text: ui("当前分类暂无操作记录。", "No activity in this category.")).frame(minHeight: 160) }
            }
        }.padding(28)
            .task { await model.refreshHistory() }
            .onChange(of: model.activityFilter) { _ in selection = nil }
    }
}

struct ActivityDetail: View {
    @EnvironmentObject private var model: AppModel
    let activity: Activity
    @ViewState private var cancelConfirmation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(activity.status).font(.headline)
                if let code = activity.code { Text(ui("退出码 \(code)", "Exit code \(code)")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if activity.waiting { Button(ui("取消执行…", "Cancel Execution…")) { cancelConfirmation = true }.accessibilityIdentifier("cancel_execution").disabled(model.busy) }
                if activity.executionID != nil { Button(ui("刷新结果", "Refresh Result")) { Task { await model.readExecution(activity) } } }
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(activity.command, forType: .string) } label: { Label(ui("复制命令", "Copy Command"), systemImage: "doc.on.doc") }.disabled(!activity.hasCommandDetails)
            }
            Text(activity.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            if !activity.sandboxIDs.isEmpty { Text(ui("Sandbox：", "Sandbox: ") + activity.sandboxIDs.joined(separator: ", ")).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            if let id = activity.executionID { Text(ui("执行 ID：\(id)", "Execution ID: \(id)")).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            OutputView(text: activity.waiting ? activity.status + ui("。完成后读取标准输出和错误；实时对话请查看轨迹。\n关闭前端不会取消执行。", ". Standard output and errors are available after completion; see the trajectory for live conversations.\nClosing the frontend does not cancel execution.") : activity.output + (activity.error.isEmpty ? "" : "\n── stderr / error ──\n" + activity.error))
        }
        .task(id: (activity.executionID ?? "") + ":" + (activity.backendState ?? "")) {
            if activity.backendState != nil { await model.readExecution(activity) }
        }
        .alert(ui("请求取消执行？", "Request Execution Cancellation?"), isPresented: $cancelConfirmation) {
            Button(ui("返回", "Back"), role: .cancel) {}; Button(ui("请求取消", "Request Cancellation"), role: .destructive) { model.cancel(activity) }
        } message: { Text(ui("只调用 cancel，不直接杀进程。取消已经开始的执行可能使整个节点进入隔离状态，需要人工检查后恢复。", "Sends a cancel request without directly terminating processes. Cancelling a running execution may quarantine the node, requiring inspection before recovery.")) }
    }
}

private enum ClusterRole: String, CaseIterable {
    case standalone, manager, worker
    var title: String {
        switch self {
        case .standalone: return ui("单机", "Standalone")
        case .manager: return ui("管理节点", "Manager Node")
        case .worker: return ui("从节点", "Worker Node")
        }
    }
}

private struct ClusterNodeRow: Identifiable {
    let id = UUID()
    var value: ClusterNodeConfiguration
    var limit: String
    init(value: ClusterNodeConfiguration) {
        self.value = value; limit = value.maxConcurrentInstances.map(String.init) ?? ""
    }
    func configuration() throws -> ClusterNodeConfiguration {
        var result = value
        let pool = result.schedulingPool?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
        result.schedulingPool = pool.isEmpty || pool == "default" ? nil : pool
        if limit.isEmpty { result.maxConcurrentInstances = nil }
        else {
            guard let count = Int(limit), count >= 0 else { throw CLIError(ui("最大并发实例数需要填写非负整数。", "Maximum concurrent instances must be a nonnegative integer.")) }
            result.maxConcurrentInstances = count
        }
        return result
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var directory = ""
    @ViewState private var stateDirectory = ""
    @ViewState private var clusterConfig = ""
    @ViewState private var refresh = 5.0
    @ViewState private var role = ClusterRole.standalone
    @ViewState private var localNodeID = "manager"
    @ViewState private var sharedRoot = ""
    @ViewState private var instanceLimit = "32"
    @ViewState private var schedulingPool = "default"
    @ViewState private var crossNodeScheduling = true
    @ViewState private var nodes: [ClusterNodeRow] = []
    @ViewState private var loading = false
    @ViewState private var saving = false
    @ViewState private var showAddNode = false
    @ViewState private var configurationError: String?
    @ViewState private var configurationNotice: String?
    private var client: CLIClient {
        CLIClient(CLIConfiguration(directory: directory.isEmpty ? model.bundledDirectory : URL(fileURLWithPath: directory), stateDirectory: stateDirectory))
    }
    private var configurationPath: String {
        clusterConfig.isEmpty ? NSHomeDirectory() + "/Library/Application Support/MetalSandboxUI/cluster.json" : clusterConfig
    }
    var body: some View {
        Form {
            Section(ui("连接与命令行程序", "Connection and CLI Tools")) {
                HStack { TextField(ui("CLI 目录（留空使用 App 内置程序）", "CLI Directory (empty uses bundled tools)"), text: $directory); Button(ui("选择…", "Choose…")) { if let url = Panels.directory() { directory = url.path } } }
                Text(ui("内置：\(model.bundledDirectory.path)", "Bundled: \(model.bundledDirectory.path)")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                TextField(ui("状态目录（仅传给 CLI）", "State Directory (passed to CLI)"), text: $stateDirectory)
                Picker(ui("全局自动刷新间隔", "Automatic Refresh Interval"), selection: $refresh) { Text(ui("2 秒", "2 seconds")).tag(2.0); Text(ui("5 秒", "5 seconds")).tag(5.0); Text(ui("10 秒", "10 seconds")).tag(10.0); Text(ui("30 秒", "30 seconds")).tag(30.0) }
            }
            Section(ui("节点集群", "Node Cluster")) {
                Picker(ui("本机角色", "Local Node Role"), selection: Binding(get: { role }, set: { value in
                    if value == .worker && schedulingPool == "default" { schedulingPool = "" }
                    if value == .manager && schedulingPool.isEmpty { schedulingPool = "default" }
                    role = value
                    if ["manager", "worker", ""].contains(localNodeID), value != .standalone {
                        localNodeID = value == .manager ? "manager" : "worker"
                    }
                })) {
                    ForEach(ClusterRole.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).id(model.language).accessibilityIdentifier("cluster_role")
                HStack {
                    TextField(ui("本机最大并发实例数", "Local Maximum Concurrent Instances"), text: $instanceLimit).accessibilityIdentifier("cluster_local_limit")
                    Stepper(ui("本机最大并发实例数", "Local Maximum Concurrent Instances"), value: Binding(get: { Int(instanceLimit) ?? 32 }, set: { instanceLimit = String($0) }), in: 0...Int.max).labelsHidden()
                }
                Text(ui("已停止的实例不占名额；0 表示不接收新实例。", "Stopped instances do not use capacity; 0 rejects new instances.")).font(.caption).foregroundStyle(.secondary)
                if role != .standalone {
                    TextField(ui("本机节点名称", "Local Node Name"), text: $localNodeID).accessibilityIdentifier("cluster_local_node")
                    if role == .manager {
                        TextField(ui("本机调度池", "Local Scheduling Pool"), text: $schedulingPool, prompt: Text("default"))
                            .accessibilityIdentifier("cluster_local_pool")
                        Toggle(ui("允许本机跨节点调度", "Allow Local Cross-node Scheduling"), isOn: $crossNodeScheduling)
                            .accessibilityIdentifier("cluster_local_cross_node")
                    } else {
                        TextField(ui("允许的调度池（留空不限制）", "Allowed Scheduling Pools (empty permits all)"), text: $schedulingPool)
                            .accessibilityIdentifier("cluster_local_pool")
                        Toggle(ui("允许跨节点调度", "Allow Cross-node Scheduling"), isOn: $crossNodeScheduling)
                            .accessibilityIdentifier("cluster_local_cross_node")
                    }
                    TextField(ui("集群工作目录（可选）", "Cluster Working Directory (optional)"), text: $sharedRoot).accessibilityIdentifier("cluster_shared_root")
                    Text(ui("实例数据保存在该目录下的本机节点子目录。同池节点需将它挂载到相同路径。", "Instance data is stored in this directory's local-node subdirectory. Nodes in the same pool must mount it at the same path.")).font(.caption).foregroundStyle(.secondary)
                    if role == .manager {
                        ForEach($nodes) { $node in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(ui("从节点", "Worker Node")).font(.headline)
                                    Spacer()
                                    Button(role: .destructive) {
                                        let id = node.id
                                        nodes.removeAll { $0.id == id }
                                    } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless).help(ui("删除节点", "Remove Node")).accessibilityLabel(ui("删除节点", "Remove Node"))
                                }
                                TextField(ui("节点名称", "Node Name"), text: $node.value.id).accessibilityIdentifier("cluster_remote_name")
                                TextField(ui("SSH 地址，例如 user@host", "SSH Destination, e.g. user@host"), text: $node.value.sshDestination).accessibilityIdentifier("cluster_remote_ssh")
                                TextField(ui("远端 sandboxctl 路径", "Remote sandboxctl Path"), text: $node.value.cliPath).accessibilityIdentifier("cluster_remote_cli")
                                TextField(ui("远端状态目录", "Remote State Directory"), text: $node.value.stateDirectory).accessibilityIdentifier("cluster_remote_state")
                                TextField(ui("最大并发实例数（留空跟随从节点）", "Maximum Instances (empty follows worker)"), text: $node.limit).accessibilityIdentifier("cluster_remote_limit")
                                TextField(ui("调度池", "Scheduling Pool"), text: Binding(get: { node.value.schedulingPool ?? "default" },
                                    set: { node.value.schedulingPool = $0 }), prompt: Text("default"))
                                    .accessibilityIdentifier("cluster_remote_pool")
                                Toggle(ui("允许跨节点调度", "Allow Cross-node Scheduling"), isOn: Binding(get: { node.value.crossNodeSchedulingEnabled != false },
                                    set: { node.value.crossNodeSchedulingEnabled = $0 ? nil : false }))
                                    .accessibilityIdentifier("cluster_remote_cross_node")
                            }.padding(.vertical, 6)
                        }
                        Button { showAddNode = true } label: { Label(ui("添加从节点", "Add Worker Node"), systemImage: "plus") }
                            .accessibilityIdentifier("cluster_add_node")
                        Text(ui("分配上限同时受从节点自身上限约束。", "Assignments also respect the worker's own capacity limit.")).font(.caption).foregroundStyle(.secondary)
                        Text(ui("相同调度池的节点可互相调度串行命令；关闭跨节点调度后，该节点不调出也不接收其他节点的命令。", "Nodes in the same pool may exchange serial commands. Disabling cross-node scheduling prevents a node from sending or receiving migrated commands.")).font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent(ui("配置文件", "Configuration File")) {
                        Text(configurationPath).font(.caption).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                            .accessibilityIdentifier("cluster_configuration_path")
                        Button(ui("另存为…", "Save As…")) { if let url = Panels.save(name: "cluster.json") { clusterConfig = url.path } }
                    }
                }
                Text(ui("空闲时保存会重启服务以应用配置；有活动实例或任务时仅保存。", "Saving while idle restarts the service to apply settings; with active instances or tasks, it only saves them.")).font(.caption).foregroundStyle(.secondary)
                Button(ui("载入配置…", "Load Configuration…")) {
                    if let url = Panels.openFile() { Task { await loadCluster(at: url.path) } }
                }.accessibilityIdentifier("cluster_load")
                if let configurationError { Text(configurationError).foregroundStyle(.red).textSelection(.enabled) }
                if let configurationNotice { Text(configurationNotice).foregroundStyle(.secondary) }
                if model.serviceSettingsPending {
                    HStack {
                        Text(ui("已保存的配置尚未应用。", "Saved configuration has not been applied.")).foregroundStyle(.orange)
                        Button(ui("应用配置", "Apply Configuration")) { model.applyServiceSettings() }.disabled(!model.canApplyServiceSettings)
                    }
                }
            }
            Section {
                Button(ui("保存并应用", "Save and Apply")) { Task { await save() } }
                    .primaryAction().accessibilityIdentifier("save_settings").disabled(model.busy)
            }
            Section(ui("关于", "About")) {
                LabeledContent(ui("版本", "Version"), value: Bundle.main.object(forInfoDictionaryKey: "MetalSandboxVersion") as? String ?? ui("开发构建", "Development Build"))
                Picker(ui("语言", "Language"), selection: $model.language) {
                    ForEach(InterfaceLanguage.allCases) { language in Text(language.title).tag(language) }
                }.id(model.language).accessibilityIdentifier("interface_language")
            }.font(.callout)
        }.formStyle(.grouped).disabled(loading || saving)
        .sheet(isPresented: $showAddNode) {
            ClusterNodeWizard(client: client, reservedIDs: [localNodeID] + nodes.map { $0.value.id }) { node, _ in
                nodes.append(ClusterNodeRow(value: node))
            }
        }
        .task(id: model.configuration) {
            directory = model.directory; stateDirectory = model.stateDirectory; clusterConfig = model.clusterConfig; refresh = model.refreshSeconds
            instanceLimit = String(model.maxConcurrentInstances)
            configurationError = nil
            if clusterConfig.isEmpty {
                role = .standalone
            }
            else { await loadCluster(at: clusterConfig) }
        }
    }
    private func loadCluster(at path: String) async {
        loading = true; defer { loading = false }
        let current = model.configuration
        do {
            let document = try await client.readClusterConfiguration(at: path)
            guard !Task.isCancelled, current == model.configuration else { return }
            clusterConfig = path; role = document.nodes.isEmpty ? .worker : .manager
            localNodeID = document.localNodeID; sharedRoot = document.sharedRoot ?? ""
            instanceLimit = String(document.maxConcurrentInstances ?? 32)
            schedulingPool = document.schedulingPool ?? (role == .manager ? "default" : "")
            crossNodeScheduling = document.crossNodeSchedulingEnabled != false
            nodes = document.nodes.map { ClusterNodeRow(value: $0) }; configurationError = nil
        } catch {
            guard !Task.isCancelled, current == model.configuration else { return }
            configurationError = error.localizedDescription
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        configurationNotice = nil
        do {
            let previous = model.configuration
            let sameEndpoint = client.configuration.directory == previous.directory && stateDirectory == previous.stateDirectory
            let wasConnected = model.status != nil
            guard stateDirectory.hasPrefix("/"), directory.isEmpty || directory.hasPrefix("/") else { throw CLIError(ui("请使用绝对路径。", "Use absolute paths.")) }
            guard let maximum = Int(instanceLimit), maximum >= 0 else { throw CLIError(ui("最大并发实例数需要填写非负整数。", "Maximum concurrent instances must be a nonnegative integer.")) }
            if role != .standalone {
                guard role != .manager || !nodes.isEmpty else { throw CLIError(ui("请至少添加一个从节点。", "Add at least one worker node.")) }
                var document = ClusterConfigurationDocument(localNodeID: localNodeID, sharedRoot: sharedRoot.isEmpty ? nil : sharedRoot,
                    nodes: role == .manager ? try nodes.map { try $0.configuration() } : [], maxConcurrentInstances: maximum)
                let pool = schedulingPool.trimmingCharacters(in: .whitespacesAndNewlines)
                document.schedulingPool = pool.isEmpty || (role == .manager && pool == "default") ? nil : pool
                document.crossNodeSchedulingEnabled = crossNodeScheduling ? nil : false
                try await client.saveClusterConfiguration(document, at: configurationPath)
                clusterConfig = configurationPath
            }
            model.directory = directory; model.stateDirectory = stateDirectory; model.refreshSeconds = refresh
            model.maxConcurrentInstances = maximum
            model.clusterConfig = role == .standalone ? "" : clusterConfig; model.saveSettings()
            configurationError = nil
            if sameEndpoint && wasConnected {
                configurationNotice = try await model.applySavedServiceSettings()
                    ? ui("配置已应用。", "Configuration applied.") : ui("配置已保存；请在活动实例和命令结束后应用。", "Configuration saved; apply it after active instances and commands finish.")
            } else { configurationNotice = ui("连接设置已保存。", "Connection settings saved.") }
        } catch { configurationError = error.localizedDescription }
    }
}
