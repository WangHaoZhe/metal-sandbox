import SwiftUI
import AppKit
import FrontendCore

struct InstanceView: View {
    @EnvironmentObject private var model: AppModel
    let instance: SandboxInstance
    @ViewState private var tab = "概览"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(instance.displayState, systemImage: "shippingbox").font(.title2.bold())
                    Text(instance.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                ExecutionCountsView(counts: instance.executionCounts)
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("instance_execution_counts")
            }
            InstancePagePicker(selection: $tab).frame(maxWidth: .infinity)
            if !instance.isActive && tab == "终端" { Note(text: ui("执行命令前请先启动原实例。", "Start the original instance before running commands."), warning: true) }
            if !instance.isActive && tab == "准备" { Note(text: ui("可编辑或导入准备文件；执行脚本前请先启动原实例。", "You may edit or import preparation files; start the original instance before running scripts.")) }
            Group {
                switch tab {
                case "轨迹": TrajectoryView(instance: instance, browser: model.trajectory(for: instance.id))
                case "验收": VerificationView(instance: instance, session: model.verification(for: instance.id))
                case "终端": TerminalView(instance: instance, session: model.terminal(for: instance.id))
                case "文件": FilesView(instance: instance, browser: model.workspace(for: instance.id))
                case "准备": PreparationView(instance: instance, session: model.preparation(for: instance.id))
                case "配置与快照": SnapshotView(instance: instance)
                default: overview
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(28)
        .task(id: tab + ":" + String(model.compatible)) {
            guard model.compatible else { return }
            do { try await model.inspect(instance.id) }
            catch { if !Task.isCancelled { model.alert = error.localizedDescription } }
        }

    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox(ui("实例信息", "Instance Information")) {
                    VStack(spacing: 12) {
                        LabeledContent(ui("创建时间", "Created"), value: Date(timeIntervalSince1970: instance.createdAt / 1000).formatted())
                        LabeledContent(ui("运行版本数", "Runtime Versions"), value: String(instance.revisions))
                        LabeledContent(ui("出站联网", "Outbound Network"), value: instance.networkClient == true ? ui("允许", "Allowed") : ui("关闭", "Disabled"))
                        if let node = instance.nodeID { LabeledContent(ui("节点", "Node"), value: node) }
                        if instance.dynamicScheduling == true { LabeledContent(ui("动态调度", "Dynamic Scheduling"), value: ui("开启", "Enabled")) }
                        LabeledContent(ui("快照内文件数", "Snapshot Files"), value: String(instance.checkpointFiles ?? 0))
                        LabeledContent(ui("快照大小", "Snapshot Size"), value: ByteCountFormatter.string(fromByteCount: Int64(instance.checkpointBytes ?? 0), countStyle: .file))
                        if let physical = instance.physical {
                            LabeledContent("Host PID", value: String(physical.pid))
                            LabeledContent(ui("工作区", "Workspace")) { Text(physical.workspace).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        }
                    }.labeledContentStyle(CenteredInstanceInformationStyle())
                        .padding(12).frame(maxWidth: .infinity, alignment: .center)
                }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("instance_information")
                if let error = instance.error { Note(text: error, warning: true) }
                if let error = instance.checkpointError { Note(text: ui("快照错误：", "Snapshot error: ") + error, warning: true) }
                Note(text: ui("启动原实例保留 ID、工作区和私有 HOME；从快照克隆创建新 ID，仅复制已保存的工作区。两者都不会重放历史命令。", "Starting an instance preserves its ID, workspace and private HOME. Cloning a snapshot creates a new ID and copies only the saved workspace. Neither operation replays commands."))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InstancePagePicker: NSViewRepresentable {
    @Binding var selection: String
    private static let keys = ["概览", "准备", "轨迹", "验收", "终端", "文件", "配置与快照"]
    private var titles: [String] {
        [ui("概览", "Overview"), ui("准备", "Preparation"), ui("轨迹", "Trajectory"), ui("验收", "Verification"), ui("终端", "Terminal"), ui("文件", "Files"), ui("配置与快照", "Settings and Snapshots")]
    }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: titles, trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.select(_:)))
        control.segmentDistribution = .fillEqually
        control.setAccessibilityIdentifier("instance_tabs")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        for (index, title) in titles.enumerated() { control.setLabel(title, forSegment: index) }
        control.setAccessibilityLabel(ui("实例页面", "Instance Pages"))
        let index = Self.keys.firstIndex(of: selection) ?? 0
        if control.selectedSegment != index { control.selectedSegment = index }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }
    func makeCoordinator() -> Coordinator { Coordinator($selection) }
    final class Coordinator: NSObject {
        var selection: Binding<String>
        init(_ selection: Binding<String>) { self.selection = selection }
        @objc func select(_ sender: NSSegmentedControl) {
            guard InstancePagePicker.keys.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = InstancePagePicker.keys[sender.selectedSegment]
        }
    }
}

private struct CenteredInstanceInformationStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 16) {
            configuration.label.frame(minWidth: 0, maxWidth: .infinity, alignment: .center)
            configuration.content.frame(minWidth: 0, maxWidth: .infinity, alignment: .center)
        }.multilineTextAlignment(.center)
    }
}

struct FilesView: View {
    @EnvironmentObject private var model: AppModel
    let instance: SandboxInstance
    @ObservedObject var browser: WorkspaceBrowser
    private var available: Bool { model.filesAvailable(instance) }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("workspace").font(.headline)
                        .contextMenu {
                            Button(ui("在访达中显示", "Reveal in Finder")) { model.revealWorkspace(instance.id, path: ".", configuration: browser.configuration) }
                                .disabled(!available || !model.canMutate || model.status?.workspaceRevealImplemented != true)
                        }
                    Spacer()
                    Button { Task { await browser.refresh(app: model) } } label: { Image(systemName: "arrow.clockwise") }
                        .help(ui("刷新工作区目录", "Refresh Workspace Directory")).accessibilityIdentifier("refresh_workspace")
                        .disabled(!available || model.status?.directoryListingImplemented != true || !browser.loading.isEmpty)
                }
                if !available {
                    Text(ui("工作区暂不可用。", "Workspace Unavailable"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else if model.status?.directoryListingImplemented == true {
                    Viewport {
                        List { WorkspaceTree(browser: browser, path: ".", choose: { entry in Task { await browser.open(entry, app: model) } }) }
                            .listStyle(.plain).disabled(browser.loadingFile)
                    }
                } else {
                    Text(ui("管理服务未提供目录浏览。", "The manager does not provide directory browsing."))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }.frame(minWidth: 150, idealWidth: 210, maxWidth: 300).padding(.trailing, 10)
            VStack(alignment: .leading, spacing: 12) {
                Text(browser.selected?.path ?? ui("选择文件", "Select File"))
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle).help(browser.selected?.path ?? ui("选择文件", "Select File"))
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("workspace_preview_path")
                HStack {
                    Button(ui("刷新预览", "Refresh Preview")) { Task { await browser.read(app: model) } }
                        .accessibilityIdentifier("refresh_file_preview")
                        .disabled(!available || browser.loadingFile || browser.selected?.kind != .file)
                    Button(ui("下载文件…", "Download File…")) {
                        if let entry = browser.selected, let destination = Panels.save(name: entry.name) {
                            let client = CLIClient(browser.configuration)
                            Task {
                                do { try await model.command(["read", instance.id, entry.path, "--out", destination.path], title: ui("下载工作区文件", "Download Workspace File"), client: client) }
                                catch { model.alert = error.localizedDescription }
                            }
                        }
                    }.accessibilityIdentifier("download_file")
                        .disabled(!available || browser.selected?.kind != .file)
                    Spacer()
                    ZStack { if browser.loadingFile { ProgressView().controlSize(.small) } }.frame(width: 16, height: 16)
                }
                if let entry = browser.selected {
                    Text("\(entry.kind.rawValue) · \(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)) · \(Date(timeIntervalSince1970: entry.modifiedAt / 1000).formatted())")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let message = browser.previewMessage { Note(text: message) }
                Viewport {
                    if let preview = browser.preview {
                        if let text = preview.text {
                            TerminalOutputView(text: text.isEmpty ? ui("空文件", "Empty file") : text, autoScroll: false,
                                               accessibilityIdentifier: "workspace_text_preview", accessibilityLabel: ui("文件内容预览", "File Content Preview"))
                        } else { SystemFilePreview(preview: preview).id(preview.file) }
                    } else {
                        Text(browser.loadingFile ? ui("正在读取文件…", "Reading File…") : ui("选择文件查看预览", "Select a File to Preview"))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minHeight: 100)
                    .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                if browser.preview?.textTruncated == true {
                    Text(ui("文本仅显示前 4 MiB；下载可获取完整文件。", "Text preview is limited to 4 MiB; downloading retrieves the full file.")).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(minWidth: 320).padding(.leading, 10)
        }
        .task(id: available) { if available && model.status?.directoryListingImplemented == true { await browser.refresh(app: model) } }
    }
}

struct PreparationView: View {
    @EnvironmentObject private var model: AppModel
    let instance: SandboxInstance
    @ObservedObject var session: PreparationSession
    @ViewState private var importURL: URL?
    @ViewState private var importing = false
    @ViewState private var reloading = false
    @ViewState private var submitted = false
    private var available: Bool { model.filesAvailable(instance) && model.canMutate && !session.loading && session.loaded && session.error == nil }
    private var timeout: Double? {
        guard let value = Double(session.timeoutText), value.isFinite, value > 0 else { return nil }
        return value
    }
    private func adjustTimeout(_ step: Double) {
        let value = (timeout ?? 3600) + step
        if value.isFinite && value > 0 { session.timeoutText = String(value) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ui("准备脚本 · setup.sh", "Preparation Script · setup.sh")).font(.headline)
                ZStack {
                    if session.loading {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel(ui("读取工作区准备文件", "Read Workspace Preparation Files"))
                            .accessibilityIdentifier("preparation_loading")
                            .help(ui("读取工作区准备文件…", "Read Workspace Preparation Files…"))
                    }
                }.frame(width: 16, height: 16)
                Spacer()
                Button(ui("重新读取", "Reload")) {
                    if session.dirty { reloading = true } else { Task { await session.reload(app: model) } }
                }.disabled(!model.filesAvailable(instance) || !model.canMutate || session.loading)
                Button(ui("载入脚本…", "Load Script…")) { if let file = Panels.openFile() { loadScript(file) } }
                    .disabled(!available)
            }
            if let error = session.error { Note(text: ui("读取失败：", "Read failed: ") + error, warning: true) }
            Text(session.dirty ? ui("有未保存修改；执行前会保存当前内容。", "Unsaved changes will be saved before execution.") : session.saved.script == nil ? ui("暂无 setup.sh。导入题包后会自动读取，也可自行编写。", "No setup.sh yet. Import a task to load it, or write your own.") : ui("已读取工作区 setup.sh；保存并执行使用下方内容。", "Workspace setup.sh loaded; Save and Run uses the content below."))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("preparation_source")
            Viewport { TextEditor(text: Binding(get: { session.files.script ?? "" }, set: { session.files.script = $0 })).font(.system(.body, design: .monospaced)).accessibilityLabel(ui("准备脚本", "Preparation Script")) }
                .frame(minHeight: 130).border(Color.secondary.opacity(0.2))
                .disabled(!available)
            HStack {
                Text(ui("题目 · instruction.md", "Task · instruction.md")).font(.headline)
                Spacer()
                Button(ui("导入题包…", "Import Task Package…")) { if let file = Panels.taskPackage() { importURL = file; importing = true } }
                    .accessibilityIdentifier("import_task_package")
                Button(ui("载入题目…", "Load Instruction…")) {
                    if let file = Panels.openFile() {
                        do { session.files.instruction = try String(contentsOf: file, encoding: .utf8) }
                        catch { model.alert = error.localizedDescription }
                    }
                }
            }.disabled(!available)
            Viewport { TextEditor(text: Binding(get: { session.files.instruction ?? "" }, set: { session.files.instruction = $0 })).font(.system(.body, design: .monospaced)).accessibilityLabel(ui("题目 instruction.md", "Task instruction.md")) }
                .frame(minHeight: 70, maxHeight: 110).border(Color.secondary.opacity(0.2)).disabled(!available)
            HStack {
                Button(ui("保存", "Save")) { model.perform { try await session.save(app: model) } }
                    .disabled(!available || !session.dirty || session.verificationTimeout == nil).accessibilityIdentifier("save_preparation")
                Button(ui("保存并执行准备", "Save and Run Preparation")) {
                    guard let timeout else { return }
                    model.perform {
                        try await session.save(app: model, runTimeout: timeout)
                        submitted = true
                    }
                }.primaryAction().accessibilityIdentifier("run_preparation")
                    .disabled(!instance.isActive || !available || !model.canCreate || timeout == nil || session.verificationTimeout == nil || (session.files.script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(ui("查看执行结果", "View Execution Result")) { model.page = .activity }
            }
            HStack(spacing: 8) {
                Text(ui("准备超时", "Preparation Timeout"))
                TextField(ui("秒数", "Seconds"), text: $session.timeoutText)
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                    .accessibilityLabel(ui("准备超时秒数", "Preparation Timeout in Seconds")).accessibilityIdentifier("preparation_timeout")
                Stepper(ui("调整准备超时", "Adjust Preparation Timeout"), onIncrement: { adjustTimeout(30) }, onDecrement: { adjustTimeout(-30) })
                    .labelsHidden().fixedSize().accessibilityIdentifier("preparation_timeout_stepper")
                Text(timeout == nil ? ui("秒（请输入正数）", "seconds (enter a positive value)") : ui("秒", "seconds")).foregroundStyle(timeout == nil ? Color.red : Color.secondary)
            }
            if session.verification.testPackageSHA256 != nil {
                HStack {
                    Toggle(ui("完成后自动验收", "Verify Automatically after Completion"), isOn: $session.verification.enabled)
                        .accessibilityIdentifier("preparation_auto_verify")
                    Text(ui("验收超时", "Verification Timeout"))
                    TextField(ui("秒数", "Seconds"), text: $session.verificationTimeoutText).textFieldStyle(.roundedBorder).frame(width: 90)
                        .accessibilityIdentifier("preparation_verification_timeout")
                    Text(ui("秒", "seconds")).foregroundStyle(.secondary)
                }.disabled(!available)
            }
            Note(text: ui("题包的 agent/ 提供 instruction.md 和 setup.sh；导入后自动读取，点击执行才运行脚本。脚本可使用任意工具或 harness。", "The task's agent/ directory provides instruction.md and setup.sh. Import loads them; scripts run only when requested and may use any tool or harness. ") + (instance.networkClient == true ? ui("出站联网已允许。", "Outbound networking is allowed. ") : ui("出站联网关闭（需创建时开启）。", "Outbound networking is disabled (enable at creation). ")) + ui("超时包含完整执行过程。若在脚本中填写 API key，它也会进入工作区快照；分享前请移除。", "The timeout covers the complete execution. API keys in scripts enter workspace snapshots; remove them before sharing."))
        }
        .task(id: model.filesAvailable(instance)) { if model.filesAvailable(instance) { await session.reload(app: model, preservingDraft: true) } }
        .alert(ui("准备任务已提交", "Preparation Submitted"), isPresented: $submitted) {
            Button(ui("好", "OK"), role: .cancel) {}
        } message: { Text(ui("任务已提交到后台", "The task was submitted to the background")) }
        .alert(ui("放弃草稿并重新读取？", "Discard Drafts and Reload?"), isPresented: $reloading) {
            Button(ui("取消", "Cancel"), role: .cancel) {}
            Button(ui("重新读取", "Reload"), role: .destructive) { Task { await session.reload(app: model) } }
        }
        .alert(ui("导入题包并覆盖同路径文件？", "Import Task and Overwrite Matching Files?"), isPresented: $importing) {
            Button(ui("取消", "Cancel"), role: .cancel) { importURL = nil }
            Button(ui("导入", "Import"), role: .destructive) {
                if let file = importURL {
                    model.perform {
                        try await model.command(["import", instance.id, "--from", file.path, "--task"], title: ui("导入题包", "Import Task Package"), client: CLIClient(session.configuration))
                        await session.reload(app: model)
                        if session.loaded && (session.files.instruction == nil || session.files.script == nil) { throw CLIError(ui("未能读取题包的 instruction.md 或 setup.sh，请重新读取。", "Could not read instruction.md or setup.sh from the task package; reload the files.")) }
                    }
                }
                importURL = nil
            }
        } message: { Text(ui("仅将题包 agent/ 的内容导入工作区根目录，tests/ 留到验收时再导入。导入后重新读取 instruction.md 和 setup.sh，并放弃未保存草稿；不会自动执行脚本。", "Imports only agent/ into the workspace root; tests/ is imported for verification. Reloads instruction.md and setup.sh and discards unsaved drafts without running scripts.")) }
    }
    private func loadScript(_ file: URL) {
        do { session.files.script = try String(contentsOf: file, encoding: .utf8) }
        catch { model.alert = error.localizedDescription }
    }
}

struct SnapshotView: View {
    @EnvironmentObject private var model: AppModel
    let instance: SandboxInstance
    @ViewState private var importURL: URL?
    @ViewState private var importing = false
    @ViewState private var permissions: Set<String> = ["read", "write", "export", "exec"]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox(ui("命令调度规则", "Command Scheduling Rules")) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let policy = instance.taskPolicy {
                            Text(policy.mode == .allowlist ? ui("白名单：命中并行，其余串行", "Allowlist: matches parallel, others serial") : ui("黑名单：命中串行，其余并行", "Denylist: matches serial, others parallel"))
                                .font(.headline).accessibilityIdentifier("instance_task_policy_mode")
                            OutputView(text: (try? policy.json()) ?? ui("无法显示调度规则 JSON", "Cannot display scheduling rules JSON"),
                                       accessibilityIdentifier: "instance_task_policy", accessibilityLabel: ui("命令调度规则 JSON", "Command Scheduling Rules JSON"))
                                .id(instance.id).frame(height: 220).frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                            Text(ui("创建时保存，只读；启动原实例或快照克隆时沿用。规则涵盖整项任务及子进程，不会逐个拦截子进程或检测 GPU。", "Read-only rules saved at creation and retained on restart or cloning. They cover entire tasks and descendants without intercepting individual child processes or detecting GPU calls."))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(ui("此实例未记录独立调度规则；启动原实例或快照克隆时使用服务当前默认配置。", "This instance has no saved rules; restarting or cloning uses the service's current defaults."))
                                .foregroundStyle(.secondary)
                        }
                    }.padding(12)
                }
                InstanceEnvironmentView(session: model.environment(for: instance.id))
                GroupBox(ui("工作区快照", "Workspace Snapshots")) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Button(ui("保存快照", "Save Snapshot")) { model.perform { try await model.command(["snapshot", instance.id], title: ui("保存快照", "Save Snapshot")) } }
                                .accessibilityIdentifier("save_snapshot")
                                .disabled(model.status?.explicitSnapshotsImplemented != true)
                            Button(ui("导出快照…", "Export Snapshot…")) { if let file = Panels.save(name: "workspace_snapshot.zip") { model.perform { try await model.command(["export", instance.id, "--out", file.path], title: ui("导出快照", "Export Snapshot")) } } }.accessibilityIdentifier("export_snapshot")
                            Button(ui("导入快照…", "Import Snapshot…")) { if let file = Panels.openFile() { importURL = file; importing = true } }.accessibilityIdentifier("import_snapshot")
                        }
                        Text(ui("文件改动直接保存在工作区。保存快照、导出或停止时更新恢复快照；普通命令和文件写入不生成快照。", "File changes are saved directly in the workspace. Saving, exporting or stopping updates the recovery snapshot; ordinary commands and file writes do not create snapshots."))
                            .font(.caption).foregroundStyle(.secondary)
                        Note(text: ui("快照无大小上限，使用 .zip 格式。import 合并文件且可能覆盖同名文件，不删除其他文件；中途失败可能已经写入部分内容。", "Snapshots use .zip with no size limit. Import merges files and may overwrite matching names without deleting others. A failed import may already have written some content."))
                    }.padding(12)
                }.disabled(!model.filesAvailable(instance) || !model.canMutate)
                GroupBox(ui("限定权限的实例 Handle", "Scoped Instance Handle")) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(["read", "write", "export", "exec"], id: \.self) { name in
                            Toggle(name, isOn: Binding(get: { permissions.contains(name) }, set: { if $0 { permissions.insert(name) } else { permissions.remove(name) } }))
                        }
                        Button(ui("导出 Handle…", "Export Handle…")) {
                            if let file = Panels.save(name: "sandbox_handle.json") { model.perform { try await model.command(["grant", instance.id, "--operations", permissions.sorted().joined(separator: ","), "--out", file.path], title: ui("导出 scoped handle", "Export Scoped Handle")) } }
                        }.accessibilityIdentifier("export_handle").disabled(permissions.isEmpty)
                        Note(text: ui("Handle 是凭据，仅保存在可信控制端；不要上传到 sandbox 或交给候选程序。前端不读取导出的凭据内容。", "A handle is a credential for a trusted controller. Do not upload it to a sandbox or give it to candidate programs. The frontend does not read exported credentials."))
                    }.padding(12)
                }.disabled(!instance.isActive || !model.canMutate)
            }
        }
        .alert(ui("导入并覆盖同路径文件？", "Import and Overwrite Matching Files?"), isPresented: $importing) {
            Button(ui("取消", "Cancel"), role: .cancel) { importURL = nil }
            Button(ui("导入", "Import"), role: .destructive) { if let file = importURL { model.perform { try await model.command(["import", instance.id, "--from", file.path], title: ui("导入快照", "Import Snapshot")) } }; importURL = nil }
        } message: { Text(ui("建议先导出备份。此操作不是事务，不保证失败时回滚。", "Export a backup first. This operation is not transactional and does not guarantee rollback on failure.")) }
    }
}
