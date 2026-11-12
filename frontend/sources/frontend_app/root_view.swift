import SwiftUI
import FrontendCore

struct RootView: View {
    let appDelegate: AppDelegate
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var phase
    @ViewState private var search = ""
    @ViewState private var showCreate = false
    @ViewState private var contentHeight: CGFloat = 640
    @ViewState private var count = 1
    @ViewState private var sandboxName = ""
    @ViewState private var renamingID: String?
    @ViewState private var renameText = ""
    @FocusState private var renameFocused: Bool
    @ViewState private var networkClient = true
    @ViewState private var dynamicScheduling = false
    @ViewState private var selectedPool = ""
    @ViewState private var selectedNode = ""
    @ViewState private var showAdvancedCreate = false
    @ViewState private var showEnvironment = false
    @ViewState private var environmentRows: [EnvironmentRow] = []
    private var environmentError: String? {
        do { _ = try EnvironmentDocument.values(environmentRows); return nil } catch { return error.localizedDescription }
    }
    @ViewState private var showPreparationCreate = false
    @ViewState private var preparationScript = ""
    @ViewState private var taskPackage: URL?
    @ViewState private var taskPackageError: String?
    @ViewState private var preparationTimeoutText = "3600"
    @ViewState private var taskHasTests = false
    @ViewState private var autoVerify = true
    @ViewState private var verificationTimeoutText = "600"
    private var verificationTimeout: Double? {
        guard let value = Double($verificationTimeoutText.wrappedValue), value.isFinite, value > 0 else { return nil }
        return value
    }
    private var hasPreparation: Bool { !preparationScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var preparationTimeout: Double? {
        guard let value = Double(preparationTimeoutText), value.isFinite, value > 0 else { return nil }
        return value
    }
    private func adjustPreparationTimeout(_ step: Double) {
        let value = (preparationTimeout ?? 3600) + step
        if value.isFinite && value > 0 { preparationTimeoutText = String(value) }
    }
    @ViewState private var taskPolicyMode: TaskPolicyDocument.Mode = .allowlist
    @ViewState private var taskPolicyDrafts: [TaskPolicyDocument.Mode: String] = [:]
    private var taskPolicyJSON: String { taskPolicyDrafts[taskPolicyMode] ?? "" }
    private var taskPolicyText: Binding<String> {
        Binding(get: { taskPolicyJSON }, set: { taskPolicyDrafts[taskPolicyMode] = $0 })
    }
    private var policyError: String? {
        guard model.status?.perInstanceTaskPolicyImplemented == true else { return nil }
        do {
            let policy = try TaskPolicyDocument.parse(taskPolicyJSON)
            return policy.mode == taskPolicyMode ? nil : ui("JSON 顶层字段须为 \(taskPolicyMode.rawValue)，与所选模式一致。", "The JSON top-level key must be \(taskPolicyMode.rawValue), matching the selected mode.")
        }
        catch { return error.localizedDescription }
    }
    @ViewState private var startConfirmation = false
    @ViewState private var shutdownConfirmation = false
    @ViewState private var stopConfirmation = false
    @ViewState private var stopInstanceID: String?
    @ViewState private var deleteInstanceID: String?
    @ViewState private var showRecovery = false
    @ViewState private var sidebar = SidebarSelection()
    @ViewState private var sandboxesExpanded = true
    @ViewState private var toolsExpanded = true
    @ViewState private var pendingBatch: BatchConfirmation?
    private var visibleInstances: [SandboxInstance] {
        model.instances.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.sidebarTitle.localizedCaseInsensitiveContains(search) || $0.displayState.contains(search) }
    }
    private var selection: Binding<Set<Page>> {
        Binding(get: { sidebar.items }, set: {
            let event = NSApp.currentEvent
            let extending = event?.modifierFlags.intersection([.command, .shift]).isEmpty == false
                || event?.type == .leftMouseDragged
            sidebar.select($0, visibleIDs: visibleInstances.map(\.id), extendingSelection: extending)
            model.page = sidebar.page
        })
    }
    @ViewBuilder private func sidebarSection<Content: View>(_ title: String, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 14.0, *) {
            Section(title, isExpanded: expanded, content: content)
        } else {
            Section(title, content: content).collapsible(true)
        }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    HStack {
                        Label(ui("总览", "Overview"), systemImage: "square.grid.2x2")
                        Spacer(minLength: 6)
                        HStack(spacing: 4) {
                            Image(systemName: model.status == nil ? "circle.dashed" : "checkmark.circle.fill")
                                .renderingMode(.original).symbolRenderingMode(.monochrome)
                            Text(model.status == nil ? ui("服务未连接", "Service Disconnected") : ui("服务已连接", "Service Connected"))
                        }.lineLimit(1)
                            .foregroundStyle(sidebar.items.contains(.overview) ? Color.white : model.status == nil ? Color.secondary : Color.green)
                            .accessibilityIdentifier("sidebar_service_status")
                    }.font(.body).tag(Page.overview)
                }
                sidebarSection("Sandbox · \(model.instances.count)", expanded: $sandboxesExpanded) {
                    ForEach(visibleInstances) { item in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: item.isActive ? "shippingbox" : "archivebox").foregroundStyle(item.isActive ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                if renamingID == item.id {
                                    TextField(ui("名称", "Name"), text: $renameText)
                                        .textFieldStyle(.roundedBorder)
                                        .focused($renameFocused)
                                        .onSubmit { finishRename() }
                                        .onExitCommand { renamingID = nil; renameFocused = false }
                                        .task { renameFocused = true }
                                        .accessibilityIdentifier("sidebar_name_editor")
                                } else {
                                    Text(item.sidebarTitle).font(item.name == nil ? Font.system(.body, design: .monospaced) : Font.body).lineLimit(1).help(item.sidebarTitle + "\n" + item.id)
                                }
                                Text(item.displayState).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Text(item.pendingExecutions.map(String.init) ?? "—")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                                .help(ui("待完成命令：运行中 + 排队中；— 表示服务未提供计数", "Pending commands: running + queued; — means no count is available"))
                                .accessibilityLabel(ui("待完成命令", "Pending Commands"))
                                .accessibilityValue(item.pendingExecutions.map(String.init) ?? ui("未知", "Unknown"))
                                .accessibilityIdentifier("sandbox_pending_" + item.id)
                        }.padding(.vertical, 3).tag(Page.sandbox(item.id))
                            .accessibilityIdentifier("sandbox_row_" + item.id)
                    }
                }
                sidebarSection(ui("工具", "Tools"), expanded: $toolsExpanded) {
                    Label(ui("操作记录", "Activity"), systemImage: "terminal").tag(Page.activity)
                    Label(ui("连接设置", "Connection Settings"), systemImage: "gearshape").tag(Page.settings)
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: Page.self) { targets in
                let selectedInstances = visibleInstances.filter { targets.contains(.sandbox($0.id)) }
                let ids = selectedInstances.map(\.id)
                if !ids.isEmpty && ids.count == targets.count {
                    Button { model.revealContainers(selectedInstances) } label: {
                        Label(ui("在访达中显示", "Reveal in Finder"), systemImage: "folder")
                    }
                    .disabled(model.busy || selectedInstances.containerBundleIDs.isEmpty)
                    .accessibilityIdentifier("reveal_sandbox_container")
                    if selectedInstances.count == 1, let instance = selectedInstances.first {
                        Button(ui("重命名", "Rename")) { renameText = instance.sidebarTitle; renamingID = instance.id }
                            .disabled(!model.canMutate)
                            .accessibilityIdentifier("rename_sandbox")
                    }
                    Divider()
                    batchMenu(action: .stop, ids: ids)
                    batchMenu(action: .delete, ids: ids)
                }
            }
            .accessibilityIdentifier("sandbox_sidebar_list")
            .navigationSplitViewColumnWidth(min: 215, ideal: 245, max: 350)
        } detail: {
            Viewport {
                switch model.page ?? .overview {
                case .overview: OverviewView(showCreate: $showCreate, startConfirmation: $startConfirmation, showRecovery: $showRecovery)
                case .sandbox(let id):
                    if let instance = model.instances.first(where: { $0.id == id }) { InstanceView(instance: instance).id(id) }
                    else { VStack(spacing: 12) { Image(systemName: "shippingbox").font(.largeTitle); Text(ui("实例信息不可用", "Instance Information Unavailable")); Text(ui("请刷新列表或检查服务连接。", "Refresh the list or check the service connection.")).foregroundStyle(.secondary) } }
                case .activity: ActivityView()
                case .settings: SettingsView()
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: Text(ui("查找 Sandbox", "Find Sandbox")))
        .toolbar { windowToolbar }
        .transparentWindowToolbar()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .onChange(of: model.page) {
            sidebar.navigate(to: $0)
            Task { await model.refresh() }
        }
        .onChange(of: renameFocused) { focused in if !focused { finishRename() } }
        .onChange(of: visibleInstances.map(\.id)) { ids in
            if let renamingID, !ids.contains(renamingID) { self.renamingID = nil }
            sidebar.prune(visibleIDs: ids, existingIDs: model.instances.map(\.id))
            model.page = sidebar.page
        }
        .onChange(of: model.instances.map(\.id)) { ids in
            sidebar.prune(visibleIDs: visibleInstances.map(\.id), existingIDs: ids)
            model.page = sidebar.page
        }
        .task {
            await model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(max(2, model.refreshSeconds)) * 1_000_000_000) } catch { return }
                if NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) { await model.refresh() }
            }
        }
        .onChange(of: phase) { if $0 == .active { Task { await model.refresh() } } }
        .onAppear { appDelegate.closeUI = { model.closeTerminals(); model.closeWorkspacePreviews() }
            appDelegate.reopenMainWindow = { openWindow(id: "main") } }
        .sheet(isPresented: $showCreate) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(ui("创建 Sandbox", "Create Sandbox")).font(.title2.bold())
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(ui("每个实例有独立工作区和命令调度规则。", "Each instance has its own workspace and command scheduling rules."))
                            TextField(ui("名称（可选）", "Name (optional)"), text: $sandboxName).textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("create_sandbox_name")
                                .help(ui("留空显示 ID 简称；批量创建时名称自动加 (1)、(2)。", "Leave empty to display a short ID. Batch names receive (1), (2), etc."))
                            Stepper(ui("数量：\(count)", "Count: \(count)"), value: $count, in: 1...16)
                            Toggle(ui("允许出站联网", "Allow Outbound Network Access"), isOn: $networkClient)
                                .disabled(model.status?.networkClientImplemented != true)
                                .accessibilityIdentifier("create_network_client")
                            if let nodes = model.status?.clusterNodes, !nodes.isEmpty {
                                Picker(ui("调度池", "Scheduling Pool"), selection: $selectedPool) {
                                    Text(ui("所有调度池", "All Scheduling Pools")).tag("")
                                    ForEach(Array(Set(nodes.map(\.pool))).sorted(), id: \.self) { Text($0).tag($0) }
                                }.accessibilityIdentifier("create_pool")
                                    .onChange(of: selectedPool) { pool in
                                        if !selectedNode.isEmpty, !nodes.contains(where: { $0.id == selectedNode && (pool.isEmpty || $0.pool == pool) }) { selectedNode = "" }
                                    }
                                Picker(ui("节点", "Node"), selection: $selectedNode) {
                                    Text(ui("自动分配", "Automatic Assignment")).tag("")
                                    ForEach(nodes.filter { selectedPool.isEmpty || $0.pool == selectedPool }) { node in Text(node.id).tag(node.id) }
                                }.accessibilityIdentifier("create_node")
                                Toggle(ui("允许动态调度串行命令", "Allow Dynamic Scheduling of Serial Commands"), isOn: $dynamicScheduling)
                                    .disabled(model.status?.sharedRoot == nil)
                                    .accessibilityIdentifier("create_dynamic_scheduling")
                            }
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ui("题包（可选）", "Task Package (optional)")).font(.headline)
                                    Text(taskPackage?.path ?? ui("未选择题包", "No Task Package Selected"))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        .help(taskPackage?.path ?? ui("选择包含 agent/instruction.md 和 agent/setup.sh 的题包文件夹。", "Choose a task directory containing agent/instruction.md and agent/setup.sh."))
                                        .accessibilityIdentifier("create_task_package_path")
                                }
                                Spacer()
                                Button(ui("导入题包…", "Import Task Package…")) {
                                    if let folder = Panels.taskPackage() {
                                        do {
                                            let script = try PreparationFiles.script(inTaskPackage: folder)
                                            taskHasTests = FileManager.default.fileExists(atPath: folder.appendingPathComponent("tests/test.sh").path)
                                            autoVerify = true
                                            taskPackage = folder; preparationScript = script
                                            taskPackageError = nil; showPreparationCreate = true
                                        } catch { taskPackageError = error.localizedDescription }
                                    }
                                }.accessibilityIdentifier("create_import_task_package")
                                    .help(ui("载入题包的 agent/setup.sh，替换当前准备脚本草稿；点击创建后才导入实例。", "Loads agent/setup.sh from the task package, replacing the preparation draft. Instances receive it only when created."))
                                if taskPackage != nil || taskPackageError != nil {
                                    Button(ui("移除", "Remove")) { taskPackage = nil; taskPackageError = nil; preparationScript = ""; taskHasTests = false }
                                        .help(ui("取消题包并清空准备脚本。", "Remove the task package and clear the preparation script."))
                                }
                            }
                            if let taskPackageError { Text(taskPackageError).font(.caption).foregroundStyle(.red) }
                            if taskHasTests {
                                HStack {
                                    Toggle(ui("完成后自动验收", "Verify Automatically after Completion"), isOn: $autoVerify).accessibilityIdentifier("create_auto_verify")
                                    Spacer()
                                    Text(ui("验收超时", "Verification Timeout"))
                                    TextField(ui("秒数", "Seconds"), text: $verificationTimeoutText).textFieldStyle(.roundedBorder).frame(width: 80)
                                        .accessibilityIdentifier("create_verification_timeout")
                                    Text(ui("秒", "seconds"))
                                }
                            }
                            DisclosureGroup(ui("准备脚本（可选）", "Preparation Script (optional)"), isExpanded: $showPreparationCreate) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(ui("有题包时先导入每个副本，再保存下方脚本并提交执行。清空脚本则只导入，不执行。", "Import each task copy, save the script below and submit it. Clearing the script imports the task without executing preparation.")).font(.caption).foregroundStyle(.secondary)
                                    Viewport { TextEditor(text: $preparationScript).font(.system(.callout, design: .monospaced))
                                        .accessibilityLabel(ui("创建时准备脚本", "Preparation Script for Creation")).accessibilityIdentifier("create_preparation_script") }
                                        .frame(height: 180).border(Color.secondary.opacity(0.2))
                                    HStack {
                                        Button(ui("载入脚本…", "Load Script…")) {
                                            if let file = Panels.openFile() {
                                                do { preparationScript = try String(contentsOf: file, encoding: .utf8) }
                                                catch { model.alert = error.localizedDescription }
                                            }
                                        }
                                        Spacer()
                                        Text(ui("超时", "Timeout"))
                                        TextField(ui("秒数", "Seconds"), text: $preparationTimeoutText).textFieldStyle(.roundedBorder).frame(width: 85)
                                            .accessibilityLabel(ui("创建时准备超时秒数", "Preparation Timeout in Seconds")).accessibilityIdentifier("create_preparation_timeout")
                                        Stepper(ui("调整准备超时", "Adjust Preparation Timeout"), onIncrement: { adjustPreparationTimeout(30) }, onDecrement: { adjustPreparationTimeout(-30) }).labelsHidden().fixedSize()
                                        Text(ui("秒", "seconds"))
                                    }
                                    if hasPreparation && preparationTimeout == nil { Text(ui("超时请输入正数秒数。", "Enter a positive timeout in seconds.")).font(.caption).foregroundStyle(.red) }
                                    Text(ui("题包包含隐藏文件，请勿夹带无关凭据。脚本中的 API key 会进入各副本的工作区快照。", "Task packages include hidden files; exclude unrelated credentials. API keys in scripts are included in each workspace snapshot.")).font(.caption).foregroundStyle(.secondary)
                                }.padding(.top, 8)
                            }.accessibilityIdentifier("create_preparation_options")
                            DisclosureGroup(ui("环境变量", "Environment Variables"), isExpanded: $showEnvironment) {
                                VStack(alignment: .leading, spacing: 8) {
                                    EnvironmentEditor(rows: $environmentRows)
                                    if let environmentError { Text(environmentError).foregroundStyle(.red).font(.caption) }
                                    if model.status?.environmentImplemented != true { Text(ui("管理服务未提供此功能。", "The manager does not provide this feature.")).foregroundStyle(.secondary) }
                                }.padding(.top, 8)
                            }.accessibilityIdentifier("create_environment_options")
                            DisclosureGroup(ui("高级选项", "Advanced Options"), isExpanded: $showAdvancedCreate) {
                                VStack(alignment: .leading, spacing: 8) {
                                    if model.status?.perInstanceTaskPolicyImplemented == true {
                                        Picker(ui("调度模式", "Scheduling Mode"), selection: $taskPolicyMode) {
                                            Text(ui("白名单：命中并行，其余串行", "Allowlist: matches parallel, others serial")).tag(TaskPolicyDocument.Mode.allowlist)
                                            Text(ui("黑名单：命中串行，其余并行", "Denylist: matches serial, others parallel")).tag(TaskPolicyDocument.Mode.blocklist)
                                        }.pickerStyle(.menu).accessibilityIdentifier("create_task_policy_mode")
                                        Text((taskPolicyMode == .allowlist ? ui("并行命令白名单", "Parallel Command Allowlist") : ui("串行命令黑名单", "Serial Command Denylist")) + " · JSON").font(.headline)
                                        Viewport { TextEditor(text: taskPolicyText).font(.system(.callout, design: .monospaced))
                                            .accessibilityLabel(ui("命令调度规则 JSON", "Command Scheduling Rules JSON")).accessibilityIdentifier("create_task_policy") }
                                            .frame(height: 220).border(Color.secondary.opacity(0.2))
                                        Text(ui("匹配完整程序路径及参数前缀，规则涵盖整项任务及子进程，不会逐个拦截子进程或检测 GPU。多个实例使用本次填写的同一份配置。", "Rules match full program paths and argument prefixes and cover entire tasks and descendants. They do not intercept individual child processes or detect GPU calls. All new instances use these rules."))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if taskPolicyMode == .blocklist {
                                            Text(ui("黑名单为空时，所有任务都可跨实例并行；未匹配的 GPU 任务也不会排队。", "An empty denylist allows all tasks to run concurrently across instances, including unmatched GPU tasks."))
                                                .font(.caption).foregroundStyle(.orange)
                                        }
                                    } else {
                                        Text(ui("管理服务未提供实例调度配置。", "The manager does not provide instance scheduling configuration.")).foregroundStyle(.secondary)
                                    }
                                }.padding(.top, 8)
                            }.accessibilityIdentifier("create_advanced_options")
                            if let policyError { Text(policyError).font(.caption).foregroundStyle(.red) }
                            Text(ui("等价命令：", "Equivalent command: ") + "sandboxctl sandbox create --count \(count)\(sandboxName.isEmpty ? "" : " " + CommandInput.display(["--name", sandboxName]))\(networkClient ? "" : " --no_network")\(selectedPool.isEmpty ? "" : " " + CommandInput.display(["--pool", selectedPool]))\(selectedNode.isEmpty ? "" : " " + CommandInput.display(["--node", selectedNode]))\(dynamicScheduling ? " --dynamic-scheduling" : "")\(model.status?.perInstanceTaskPolicyImplemented == true ? " --task-policy task_policy.json" : "")").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
                    }.accessibilityIdentifier("create_form_scroll")
                    HStack {
                        Button(ui("取消", "Cancel")) { showCreate = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button(hasPreparation ? ui("创建并执行准备", "Create and Run Preparation") : ui("创建", "Create")) {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            model.create(count, name: $sandboxName.wrappedValue, networkClient: networkClient, taskPolicyJSON: model.status?.perInstanceTaskPolicyImplemented == true ? taskPolicyJSON : nil,
                                         preparationScript: preparationScript, preparationTimeout: preparationTimeout ?? 3600, taskPackage: taskPackage, environment: (try? EnvironmentDocument.values(environmentRows)) ?? [:],
                                         autoVerify: taskHasTests && $autoVerify.wrappedValue, verificationTimeout: verificationTimeout ?? 600,
                                         nodeID: selectedNode.isEmpty ? nil : selectedNode, schedulingPool: selectedPool.isEmpty ? nil : selectedPool, dynamicScheduling: dynamicScheduling)
                            showCreate = false
                        }.primaryAction().accessibilityLabel(ui("确认创建 Sandbox", "Confirm Sandbox Creation")).accessibilityIdentifier("confirm_create").keyboardShortcut(.defaultAction)
                            .disabled(!model.canCreate || policyError != nil || taskPackageError != nil || environmentError != nil || (taskHasTests && verificationTimeout == nil) || (!environmentRows.isEmpty && model.status?.environmentImplemented != true) || (hasPreparation && preparationTimeout == nil) || (networkClient && model.status?.networkClientImplemented != true))
                    }
                }.padding(24)
                    .frame(width: 560, height: min(creationHeight, max(460, contentHeight)))
                    .fixedSize()
                    .onAppear {
                        taskPolicyDrafts = Dictionary(uniqueKeysWithValues: TaskPolicyDocument.Mode.allCases.map { ($0, (try? TaskPolicyDocument(mode: $0).json()) ?? "") })
                        if let policy = model.status?.taskPolicy {
                            taskPolicyMode = policy.mode; taskPolicyDrafts[policy.mode] = try? policy.json()
                        }
                    }
                    .onDisappear {
                        sandboxName = ""; networkClient = true; showAdvancedCreate = false; taskPolicyDrafts = [:]; taskPolicyMode = .allowlist
                        dynamicScheduling = false; selectedNode = ""; selectedPool = ""
                        showPreparationCreate = false; preparationScript = ""; preparationTimeoutText = "3600"
                        taskPackage = nil; taskPackageError = nil
                        taskHasTests = false; autoVerify = true; verificationTimeoutText = "600"
                        showEnvironment = false; environmentRows = []
                    }
        }
        .sheet(isPresented: $showRecovery) { RecoveryView() }
        .sheet(item: $pendingBatch) { request in BatchConfirmationView(request: request) }
        .sheet(isPresented: Binding(get: { model.batchResult != nil }, set: { if !$0 { model.batchResult = nil } })) {
            if let result = model.batchResult { OperationResultView(result: result) }
        }
        .alert(ui("停止这个 Sandbox？", "Stop This Sandbox?"), isPresented: Binding(get: { stopInstanceID != nil }, set: { if !$0 { stopInstanceID = nil } }), presenting: stopInstanceID) { id in
            Button(ui("取消", "Cancel"), role: .cancel) {}
            Button(ui("停止", "Stop"), role: .destructive) { model.stop(id) }.accessibilityIdentifier("confirm_stop_instance")
        } message: { id in Text(ui("\(id)\n\n保存可用快照并停止实例，不删除容器。活动执行被中断可能触发节点隔离。", "\(id)\n\nSave an available snapshot and stop the instance without deleting the container. Interrupting active execution may quarantine the node.")) }
        .alert(ui("永久删除这个 Sandbox？", "Permanently Delete This Sandbox?"), isPresented: Binding(get: { deleteInstanceID != nil }, set: { if !$0 { deleteInstanceID = nil } }), presenting: deleteInstanceID) { id in
            Button(ui("取消", "Cancel"), role: .cancel) {}
            Button(ui("永久删除", "Permanently Delete"), role: .destructive) { model.delete(id) }.accessibilityIdentifier("confirm_delete_instance")
        } message: { id in
            Text(ui("\(id)\n\n将永久删除容器内任务文件、快照和已登记的物理版本，不能恢复。独立导出的产物、执行记录和恢复审计保留。系统允许时一并删除容器空壳；若 macOS 拒绝，会明确列出残留。", "\(id)\n\nPermanently delete task files, snapshots and registered physical versions. Exported artifacts, execution records and recovery audits remain. The container shell is removed when permitted; any macOS-denied leftovers are listed."))
        }
        .alert(ui("启动本地管理服务？", "Start the Local Manager?"), isPresented: $startConfirmation) {
            Button(ui("取消", "Cancel"), role: .cancel) {}
            Button(ui("启动服务", "Start Service")) { model.startService() }
        } message: { Text(ui("将调用 App 自带的 metal-sandboxd --allow-trusted-code。仅用于可信代码；不会创建系统账号或安装系统服务。需要已安装 Apple Command Line Tools。", "Runs the bundled metal-sandboxd --allow-trusted-code for trusted code. It does not create system accounts or install system services. Apple Command Line Tools must be installed.")) }
        .alert(ui("关闭管理服务？", "Shut Down the Manager?"), isPresented: $shutdownConfirmation) {
            Button(ui("取消", "Cancel"), role: .cancel) {}; Button(ui("关闭服务", "Shut Down Service"), role: .destructive) { model.shutdown() }
        } message: { Text(ui("所有活动实例将停止。正在执行的任务可能触发隔离，之后需要人工检查。退出前端本身不会关闭服务。", "All active instances will stop. Running tasks may quarantine the node and require inspection. Closing the frontend itself leaves the service running.")) }
        .alert(ui("停止全部实例？", "Stop All Instances?"), isPresented: $stopConfirmation) {
            Button(ui("取消", "Cancel"), role: .cancel) {}; Button(ui("停止全部", "Stop All"), role: .destructive) { model.stopAll() }
        } message: { Text(ui("调用 stop --all；保存可用快照，不删除系统容器。", "Calls stop --all, saves available snapshots and retains system containers.")) }
        .alert(ui("操作未完成", "Operation Incomplete"), isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button(ui("好", "OK"), role: .cancel) { model.alert = nil }
        } message: { Text(model.alert ?? "") }
    }

    private var creationHeight: CGFloat {
        [showAdvancedCreate, showPreparationCreate, showEnvironment].filter { $0 }.count > 1 ? 820
            : showAdvancedCreate || showPreparationCreate || showEnvironment ? 700 : 460
    }

    @ToolbarContentBuilder private var windowToolbar: some ToolbarContent {
                    if let instance = model.selected {
                        if instance.canStop {
                            ToolbarItem(id: "instance_stop", placement: .primaryAction) {
                            Button { stopInstanceID = instance.id } label: { Label(ui("停止", "Stop"), systemImage: "stop.fill") }
                                .toolbarAction().help(ui("停止实例", "Stop Instance")).accessibilityIdentifier("stop_instance")
                                .disabled(!model.canMutate)
                            }.separateToolbarButtons()
                        }
                        if instance.canStart {
                            ToolbarItem(id: "instance_start", placement: .primaryAction) {
                            Button { model.start(instance.id) } label: { Label(ui("启动实例", "Start Instance"), systemImage: "play.fill") }
                                .toolbarAction().help(ui("启动实例", "Start Instance")).accessibilityIdentifier("start_instance")
                                .disabled(!model.canCreate || model.status?.startExistingImplemented != true)
                            }.separateToolbarButtons()
                        }
                        if instance.canRestore {
                            ToolbarItem(id: "instance_restore", placement: .primaryAction) {
                            Button { model.restore(instance.id) } label: { Label(ui("从快照克隆", "Clone from Snapshot"), systemImage: "square.on.square") }
                                .toolbarAction().help(ui("从快照克隆为新实例", "Clone Snapshot into a New Instance")).accessibilityIdentifier("restore_instance")
                                .disabled(!model.canCreate || instance.checkpointError != nil)
                            }.separateToolbarButtons()
                        }
                        ToolbarItem(id: "instance_delete", placement: .primaryAction) {
                        Button { deleteInstanceID = instance.id } label: { Label(ui("删除", "Delete"), systemImage: "trash").foregroundStyle(.red) }
                            .toolbarAction().help(ui("删除", "Delete")).accessibilityIdentifier("delete_instance")
                            .disabled(!instance.canDelete || !model.canMutate || model.status?.permanentDeletionImplemented != true)
                        }.separateToolbarButtons()
                    }
            ToolbarItemGroup(placement: .primaryAction) {
                    Button { Task { await model.refresh() } } label: { Label(ui("刷新", "Refresh"), systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                        .help(ui("刷新", "Refresh")).accessibilityIdentifier("refresh_service")
                    Button { showCreate = true } label: { Label(ui("创建 Sandbox", "Create Sandbox"), systemImage: "plus").labelStyle(.iconOnly) }
                        .help(ui("新建 Sandbox", "New Sandbox")).accessibilityIdentifier("create_sandbox").disabled(!model.canCreate)
                    Menu {
                        Button(ui("启动服务…", "Start Service…")) { startConfirmation = true }.disabled(model.status != nil || model.busy)
                        Button(ui("停止全部实例…", "Stop All Instances…")) { stopConfirmation = true }.disabled(!model.canMutate)
                        Button(ui("关闭服务…", "Shut Down Service…"), role: .destructive) { shutdownConfirmation = true }.disabled(!model.canMutate)
                        Divider()
                        Button(ui("人工恢复节点…", "Recover Node…")) { showRecovery = true }.disabled(!model.canMutate || model.status?.recoveryReason == nil)
                    } label: { Label(ui("服务操作", "Service Actions"), systemImage: "ellipsis").labelStyle(.iconOnly) }
                        .menuIndicator(.hidden).help(ui("更多服务操作", "More Service Actions")).accessibilityIdentifier("service_actions")
            }
    }

    private func finishRename() {
        guard let id = $renamingID.wrappedValue else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        let name = $renameText.wrappedValue
        renamingID = nil; renameFocused = false
        if model.instances.first(where: { $0.id == id })?.sidebarTitle != name {
            model.rename(id, name: name)
        }
    }

    @ViewBuilder private func batchMenu(action: SandboxBatchAction, ids: [String]) -> some View {
        let batch = SandboxBatch(action: action, ids: ids)
        let reason = model.batchBlockingReason(batch, configuration: model.configuration)
        Button(ui("\(action == .delete ? "删除" : action.title) \(ids.count) 个 Sandbox…", "\(action == .delete ? "Delete" : action.title) \(ids.count) Sandboxes…"), role: action == .delete ? .destructive : nil) {
            pendingBatch = BatchConfirmation(batch: batch, configuration: model.configuration)
        }.disabled(model.busy || reason != nil)
        if let reason { Text(reason).font(.caption) }
    }
}

struct BatchConfirmation: Identifiable {
    let batch: SandboxBatch
    let configuration: CLIConfiguration
    var id: UUID { batch.id }
}

struct BatchConfirmationView: View {
    let request: BatchConfirmation
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let batch = request.batch
        let reason = model.batchBlockingReason(batch, configuration: request.configuration)
        VStack(alignment: .leading, spacing: 18) {
            Text(ui("\(batch.action.title) \(batch.ids.count) 个 Sandbox？", "\(batch.action.title) \(batch.ids.count) Sandboxes?")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(batch.ids, id: \.self) { Text($0).font(.system(.callout, design: .monospaced)) }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(height: min(200, CGFloat(batch.ids.count) * 28))
            Text(batch.action == .delete
                 ? ui("将永久删除所列实例及工作区、快照和可确认归属的运行版本，不能恢复。独立导出产物与审计记录保留；系统允许时删除容器空壳，权限不足会明确列出残留。", "Permanently delete the listed instances, workspaces, snapshots and confirmed runtime versions. Exported artifacts and audit records remain. Container shells are removed when permitted; leftovers are reported.")
                 : ui("保存可用快照并停止所列实例。中断活动执行可能触发节点隔离。", "Save available snapshots and stop the listed instances. Interrupting active execution may quarantine nodes."))
            Text(ui("逐个调用现有 CLI；单个实例失败或结果未知时继续处理其余实例，最后汇总结果。不自动重试或回滚。", "Calls the CLI for each instance and collects all results. A failed or unknown result does not stop the remaining operations. No automatic retries or rollback."))
                .font(.callout).foregroundStyle(.secondary)
            if let reason { Note(text: reason, warning: true) }
            HStack {
                Button(ui("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityLabel(ui("取消", "Cancel")).accessibilityIdentifier("cancel_batch")
                Spacer()
                Button(ui("确认\(batch.action.title)", "Confirm \(batch.action.title)"), role: batch.action == .delete ? .destructive : nil) {
                    dismiss()
                    model.runBatch(batch, configuration: request.configuration)
                }.primaryAction().tint(batch.action == .delete ? .red : .accentColor)
                    .accessibilityLabel(ui("确认\(batch.action.title)", "Confirm \(batch.action.title)"))
                    .accessibilityIdentifier("confirm_batch")
                    .disabled(model.busy || reason != nil)
            }
        }.padding(28).frame(width: 560)
    }
}

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showCreate: Bool
    @Binding var startConfirmation: Bool
    @Binding var showRecovery: Bool
    @ViewState private var showAddNode = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let status = model.status {
                    HStack(spacing: 14) {
                        metric(ui("活动实例", "Active Instances"), value: String(status.activeInstances), icon: "shippingbox")
                        metric(ui("串行执行槽", "Serial Execution Slots"), value: String(status.executionSlots), icon: "cpu")
                        metric(ui("待完成命令", "Pending Commands"), value: String(status.pendingExecutions), icon: "clock", counts: status.executionCounts, showCounts: true)
                    }
                    if !model.connectionError.isEmpty { Note(text: model.connectionError, warning: true) }
                    if model.serviceSettingsPending {
                        HStack {
                            Text(ui("已保存的服务配置尚未应用。", "Saved service configuration has not been applied.")).foregroundStyle(.orange)
                            Button(ui("应用配置", "Apply Configuration")) { model.applyServiceSettings() }
                                .disabled(!model.canApplyServiceSettings).accessibilityIdentifier("apply_service_settings")
                        }
                    }
                    if let reason = status.recoveryReason {
                        GroupBox(ui("节点已隔离", "Node Quarantined")) {
                            VStack(alignment: .leading, spacing: 12) {
                                Note(text: reason, warning: true)
                                Button(ui("查看人工恢复要求…", "View Recovery Requirements…")) { showRecovery = true }.disabled(!model.canMutate)
                            }.padding(8)
                        }
                    }
                    if status.isThermallyPaused && status.recoveryReason == nil {
                        Note(text: ui("系统热压力过高，暂缓启动新任务。任务保持排队，降温后自动继续。", "Critical thermal pressure pauses new tasks. They remain queued and resume after cooling."), warning: true)
                    }
                    GroupBox {
                        NodeEnvironmentView(status: status, connected: true, monitor: model.utilization()).padding(12)
                    } label: {
                        HStack(spacing: 8) {
                            Text(ui("本机环境", "Local Environment"))
                            Text(model.nodeRoleTitle).foregroundStyle(.secondary).accessibilityIdentifier("node_role")
                            if model.runningCluster?.nodes.isEmpty == false,
                               let node = status.clusterNodes?.first(where: { $0.id == status.nodeID }) {
                                Spacer()
                                NodePoolLabel(node: node)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("local_environment")
                    ForEach((status.clusterNodes ?? []).filter { $0.id != status.nodeID }) { node in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                if let info = node.status ?? node.lastKnownStatus {
                                    NodeEnvironmentView(status: info, connected: node.status != nil, monitor: model.utilization(for: node.id))
                                } else {
                                    Text(ui("尚未读取到节点环境", "Node environment has not been loaded")).foregroundStyle(.secondary)
                                }
                                if let error = node.error ?? node.status?.recoveryReason {
                                    NodeErrorView(error: error)
                                        .accessibilityIdentifier("cluster_error_" + node.id)
                                } else if let info = node.status {
                                    Text(ui("\(info.activeInstances) / \(info.maxConcurrentInstances ?? 32) 个活跃实例 · \(info.pendingExecutions) 个待完成命令", "\(info.activeInstances) / \(info.maxConcurrentInstances ?? 32) active instances · \(info.pendingExecutions) pending commands"))
                                        .foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        } label: {
                            HStack {
                                Text(ui("节点 · \(node.id)", "Node · \(node.id)"))
                                Spacer()
                                NodePoolLabel(node: node)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("cluster_environment_" + node.id)
                    }
                    HStack(spacing: 12) {
                        Button { showCreate = true } label: { Label(ui("创建 Sandbox", "Create Sandbox"), systemImage: "plus") }
                            .controlSize(.large).primaryAction().disabled(!model.canCreate)
                            .accessibilityIdentifier("overview_create_sandbox")
                        Button { showAddNode = true } label: { Label(ui("添加节点", "Add Node"), systemImage: "plus.rectangle.on.rectangle") }
                            .controlSize(.large).disabled(model.busy).accessibilityIdentifier("overview_add_node")
                    }
                } else {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 18) {
                            Label(ui("连接你的执行环境", "Connect Your Execution Environment"), systemImage: "power").font(.title2)
                            Text(ui("App 已包含所需命令行程序。点击启动服务，再创建 sandbox；无需从源码构建。", "The app includes the CLI tools. Start the service, then create a sandbox; no source build is required."))
                            HStack {
                                Button(ui("启动服务…", "Start Service…")) { startConfirmation = true }.controlSize(.large).primaryAction().accessibilityLabel(ui("启动服务", "Start Service")).accessibilityIdentifier("start_service").disabled(model.busy)
                                Button(ui("连接设置", "Connection Settings")) { model.page = .settings }
                            }
                            if !model.connectionError.isEmpty { Text(model.connectionError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    }
                }
            }.padding(32)
        }.sheet(isPresented: $showAddNode) { OverviewAddNodeView() }
    }
    private func metric(_ title: String, value: String, icon: String, counts: ExecutionCounts? = nil, showCounts: Bool = false) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: icon).foregroundStyle(.secondary)
                metricValues(value, counts: counts, showCounts: showCounts)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
    func metricValues(_ value: String, counts: ExecutionCounts?, showCounts: Bool) -> some View {
        let number = Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.7)
        return Group {
            if showCounts {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 14) {
                        number.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 20)
                        ExecutionCountsView(counts: counts).font(.caption)
                            .padding(.trailing, 8)
                            .accessibilityIdentifier("overview_execution_counts")
                    }
                    number
                }
            } else {
                number
            }
        }.frame(height: 42, alignment: .leading)
    }
}

struct NodePoolLabel: View {
    let node: ClusterNodeStatus
    var body: some View {
        Text(ui("调度池 · \(node.pool)", "Scheduling Pool · \(node.pool)") + (node.schedulingNote.map { " · " + $0 } ?? ""))
            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            .help(node.pool).accessibilityIdentifier("node_pool_" + node.id)
    }
}

struct NodeErrorView: View {
    let error: String
    @ViewState private var showingDetails = false
    @ViewState private var hoveringLabel = false
    @ViewState private var hoveringDetails = false
    @ViewState private var dismissal: Task<Void, Never>?
    var body: some View {
        Button(ui("节点异常", "Node Error")) { showingDetails = true }
            .buttonStyle(.borderless).foregroundStyle(.red)
            .onHover {
                hoveringLabel = $0
                if $0 { dismissal?.cancel(); showingDetails = true }
                else { scheduleDismissal() }
            }
            .popover(isPresented: $showingDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    TerminalOutputView(text: error, autoScroll: false, wrapsLines: true,
                        accessibilityIdentifier: "node_error_details", accessibilityLabel: ui("节点错误详情", "Node Error Details"))
                        .frame(maxHeight: 240)
                    HStack {
                        Spacer()
                        Button(ui("复制", "Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(error, forType: .string)
                        }.accessibilityIdentifier("copy_node_error")
                    }
                }.padding(16).frame(width: 440).contentShape(Rectangle())
                    .onHover {
                        hoveringDetails = $0
                        if $0 { dismissal?.cancel() }
                        else { scheduleDismissal() }
                    }
            }
            .onChange(of: showingDetails) { if !$0 { dismissal?.cancel(); hoveringDetails = false } }
            .onDisappear { dismissal?.cancel() }
    }
    private func scheduleDismissal() {
        dismissal?.cancel()
        guard showingDetails else { return }
        dismissal = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                while NSEvent.pressedMouseButtons != 0 { try await Task.sleep(nanoseconds: 100_000_000) }
            } catch { return }
            if !hoveringLabel && !hoveringDetails { showingDetails = false }
        }
    }
}

struct NodeEnvironmentView: View {
    let status: ServiceStatus
    let connected: Bool
    let monitor: NodeUtilizationMonitor
    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            HostEnvironmentView(status: status).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            NodeUtilizationView(monitor: monitor, connected: connected).frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityElement(children: .contain).accessibilityIdentifier("node_utilization")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NodeUtilizationView: View {
    @ObservedObject var monitor: NodeUtilizationMonitor
    let connected: Bool
    var body: some View {
        let value = monitor.value
        VStack(spacing: 0) {
            meter("CPU", reading: value?.cpuPercent.map(percentText), fraction: value?.cpuPercent.map { $0 / 100 })
            meter("GPU", reading: value?.gpuPercent.map(percentText), fraction: value?.gpuPercent.map { $0 / 100 })
            capacityMeter("Mem", used: value?.memoryUsedBytes, total: value?.memoryTotalBytes)
            capacityMeter("Disk", used: value?.storageUsedBytes, total: value?.storageTotalBytes)
        }
    }
    private func percentText(_ percent: Double) -> String {
        percent.formatted(.number.precision(.fractionLength(1))) + "%"
    }
    private func capacityMeter(_ title: String, used: UInt64?, total: UInt64?) -> some View {
        guard let used, let total, total > 0 else { return meter(title, reading: nil, fraction: nil) }
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(total < 100_000_000_000 ? 1 : 0))
        let reading = "\((Double(used) / 1e9).formatted(style)) / \((Double(total) / 1e9).formatted(style)) GB"
        return meter(title, reading: reading, fraction: Double(used) / Double(total))
    }
    private func meter(_ title: String, reading: String?, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(connected ? reading ?? "—" : "—")
                    .monospacedDigit().frame(minWidth: 64, alignment: .trailing).fixedSize()
                    .accessibilityIdentifier(title.lowercased() + "_utilization")
            }
            if connected, let fraction {
                ProgressView(value: fraction).progressViewStyle(.linear)
            }
        }.frame(maxWidth: .infinity, minHeight: 40)
    }
}

struct HostEnvironmentView: View {
    let status: ServiceStatus
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 12) {
            GridRow {
                Text(ui("机型", "Model")).gridColumnAlignment(.trailing)
                Text(status.host.productName ?? ui("无法读取机型", "Model Unavailable"))
                    .gridColumnAlignment(.leading).foregroundStyle(.secondary)
                    .help(status.host.modelIdentifier).accessibilityIdentifier("host_model")
            }
            GridRow { Text(ui("Metal 设备", "Metal Device")); Text(status.host.metalDevice ?? ui("未知", "Unknown")).foregroundStyle(.secondary) }
            GridRow { Text(ui("内存", "Memory")); Text(ByteCountFormatter.string(fromByteCount: Int64(status.host.memoryBytes), countStyle: .memory)).foregroundStyle(.secondary) }
            GridRow { Text(ui("系统", "System")); Text(status.host.osVersion).foregroundStyle(.secondary) }
            GridRow { Text(ui("服务版本", "Service Version")); Text(status.serviceVersion).foregroundStyle(.secondary) }
            GridRow { Text(ui("热状态", "Thermal State")); Text(status.host.thermalState).foregroundStyle(.secondary) }
        }.textSelection(.enabled)
    }
}

struct ExecutionCountsView: View {
    let counts: ExecutionCounts?
    private func number(_ value: Int?) -> String { value.map(String.init) ?? "—" }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ui("并行任务：\(number(counts?.parallelRunning))执行中 + \(number(counts?.parallelWaiting))等待中", "Parallel tasks: \(number(counts?.parallelRunning)) running + \(number(counts?.parallelWaiting)) waiting"))
            Text(ui("串行任务：\(number(counts?.serialRunning))执行中 + \(number(counts?.serialWaiting))等待中", "Serial tasks: \(number(counts?.serialRunning)) running + \(number(counts?.serialWaiting)) waiting"))
        }.monospacedDigit().fixedSize(horizontal: true, vertical: false)
    }
}

struct RecoveryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var note = ""
    @ViewState private var confirmed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(ui("人工恢复节点", "Recover Node")).font(.title2.bold())
            Note(text: ui("请先检查遗留进程和 GPU。恢复时不能有任务命令正在执行；等待中的命令和正常的 Agent 会话可以保留。失联实例需先停止。", "Inspect leftover processes and GPU state first. Recovery requires no running task commands; queued commands and healthy agent sessions may remain. Stop disconnected instances first."), warning: true)
            TextField(ui("填写实际检查结果（必填）", "Describe Your Inspection (required)"), text: $note)
            Toggle(ui("我已在外部检查进程和 GPU 状态，并确认可以恢复", "I inspected processes and GPU state and confirmed recovery is safe"), isOn: $confirmed)
            HStack { Button(ui("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(ui("提交恢复确认", "Confirm Recovery")) { dismiss(); model.recover(note) }.disabled(!confirmed || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canMutate) }
        }.padding(28).frame(width: 540)
    }
}
