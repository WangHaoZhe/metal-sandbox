import SwiftUI
import FrontendCore

@MainActor final class VerificationSession: ObservableObject {
    let instanceID: String
    let configuration: CLIConfiguration
    @Published var taskFolder: URL?
    @Published var timeoutText = "600"
    @Published var selectedID: String?
    @Published private(set) var records: [ExecutionBrief] = []
    @Published private(set) var automatic: [ExecutionBrief] = []
    @Published private(set) var settings: VerificationSettings?
    @Published private(set) var agentState: String?
    @Published private(set) var detail: ExecutionSummary?
    @Published private(set) var nextCursor: String?
    @Published private(set) var loadingMore = false
    @Published private(set) var submitting = false
    @Published private(set) var error: String?
    private lazy var history = ExecutionHistoryReader(configuration: configuration, instanceID: instanceID) { [weak self] snapshot in
        guard let self else { return }
        let records = snapshot.records.filter { $0.verification == true }
        let automatic = snapshot.records.filter { $0.automaticVerification != nil }
        if self.automatic != automatic { self.automatic = automatic }
        if self.records != records { self.records = records }
        if self.nextCursor != snapshot.cursor { self.nextCursor = snapshot.cursor }
        if self.loadingMore != snapshot.loadingMore { self.loadingMore = snapshot.loadingMore }
        if self.error != snapshot.error { self.error = snapshot.error }
        if self.selectedID == nil { self.selectedID = records.first?.id }
    }
    init(instanceID: String, configuration: CLIConfiguration) {
        self.instanceID = instanceID; self.configuration = configuration
    }
    var timeout: Double? {
        guard let value = Double(timeoutText), value.isFinite, value > 0 else { return nil }
        return value
    }
    var pending: Bool { records.contains { ["queued", "running"].contains($0.state) } }
    func refresh(more: Bool = false) async {
        await history.refresh(more: more)
        do {
            let value = try await CLIClient(configuration).sandbox(["verification", instanceID]).reply().verificationSettings
            if settings != value { settings = value }
        } catch { self.error = error.localizedDescription }
        if !Task.isCancelled { await readSelected() }
    }
    func readSelected() async {
        guard let id = selectedID else { if detail != nil { detail = nil }; return }
        do {
            let value = try await CLIClient(configuration).sandbox(["execution", id]).reply().execution
            guard selectedID == id, !Task.isCancelled else { return }
            if detail != value { detail = value }
            if let agentID = value?.agentExecutionID {
                let state = try await CLIClient(configuration).sandbox(["execution", agentID]).reply().execution?.state
                if selectedID == id, agentState != state { agentState = state }
            } else if agentState != nil { agentState = nil }
            if history.snapshot.error == nil && error != nil { error = nil }
        } catch { if selectedID == id, !Task.isCancelled, self.error != error.localizedDescription { self.error = error.localizedDescription } }
    }
    func submit(app: AppModel) async {
        guard !submitting, let timeout else { return }
        submitting = true; error = nil; defer { submitting = false }
        do {
            selectedID = try await app.verify(instanceID, taskFolder: taskFolder, timeout: timeout, configuration: configuration)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
}

struct VerificationView: View {
    @EnvironmentObject private var model: AppModel
    let instance: SandboxInstance
    @ObservedObject var session: VerificationSession
    @ViewState private var cancelConfirmation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ui("运行工作区中的 tests/test.sh；退出码 0 表示通过，其他退出码表示未通过。", "Runs tests/test.sh in the workspace. Exit code 0 means passed; other exit codes mean not passed."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(session.taskFolder?.path ?? (session.settings?.testPackageSHA256 != nil ? ui("使用已保存的题包 tests/", "Using saved task tests/") : ui("使用工作区中的 tests/", "Using workspace tests/")))
                    .font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(ui("选择题包…", "Choose Task Package…")) { if let folder = Panels.taskPackage() { session.taskFolder = folder } }
                    .accessibilityIdentifier("verification_task_folder")
                if session.taskFolder != nil { Button(ui("清除", "Clear")) { session.taskFolder = nil } }
            }
            if session.taskFolder != nil {
                Text(ui("验收前替换整个 tests/；构建、缓存和结果均保存在 tests/ 内。", "Replaces the entire tests/ directory before verification; builds, caches and results stay within tests/."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(ui("超时（秒）", "Timeout (seconds)"))
                TextField(ui("秒", "Seconds"), text: $session.timeoutText).textFieldStyle(.roundedBorder).frame(width: 90)
                    .accessibilityIdentifier("verification_timeout")
                Button(session.taskFolder == nil ? ui("运行验收", "Run Verification") : ui("导入并运行验收", "Import and Run Verification")) { Task { await session.submit(app: model) } }
                    .primaryAction().accessibilityIdentifier("run_verification")
                    .disabled(!instance.isActive || !model.canCreate || model.status?.taskVerificationImplemented != true || session.timeout == nil || session.submitting || session.pending)
                if session.submitting { ProgressView().controlSize(.small) }
                Spacer()
                Button(ui("刷新", "Refresh")) { Task { await session.refresh() } }
                Button(ui("操作记录", "Activity")) { model.activityFilter = .sandbox(instance.id); model.page = .activity }
            }
            if !instance.isActive { Note(text: ui("可查看历史验收；运行新验收前请先启动原实例。", "View past verification here. Start the original instance before running a new verification.")) }
            if model.status?.taskVerificationImplemented != true { Note(text: ui("管理服务未提供题包验收功能。", "The manager does not provide task verification."), warning: true) }
            if let error = session.error { Note(text: error, warning: true) }
            if let latest = session.automatic.first, let automatic = latest.automaticVerification {
                Text("Agent：\(latest.state) · \(automatic.status)").font(.callout)
                if let error = automatic.error { Note(text: error, warning: true) }
            }
            HStack {
                Picker(ui("验收记录", "Verification Records"), selection: $session.selectedID) {
                    Text(ui("选择记录", "Select Record")).tag(String?.none)
                    ForEach(session.records, id: \.id) { record in
                        Text(Date(timeIntervalSince1970: record.createdAt / 1000).formatted() + " · " + record.state)
                            .tag(Optional(record.id))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("verification_history")
                if session.nextCursor != nil {
                    Button(ui("加载更早记录", "Load Earlier Records")) { Task { await session.refresh(more: true) } }.disabled(session.loadingMore)
                }
            }
            if let detail = session.detail, detail.id == session.selectedID {
                HStack {
                    Text(Verification.status(detail)).font(.headline)
                        .foregroundStyle(Verification.status(detail) == ui("通过", "Passed") ? Color.green : Color.primary)
                        .accessibilityIdentifier("verification_result")
                    if let code = detail.result?.outcome.exitCode { Text(ui("退出码 \(code)", "Exit code \(code)")).font(.caption) }
                    Spacer()
                    if ["queued", "running"].contains(detail.state) {
                        Button(ui("取消验收…", "Cancel Verification…")) { cancelConfirmation = true }.disabled(!model.canMutate)
                    }
                }
                Text(ui("执行 ID：", "Execution ID: ") + detail.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let state = session.agentState { Text(ui("Agent 执行结果：", "Agent execution result: ") + state).font(.caption) }
                if detail.metricsSaved == true { Text(ui("metrics.json 已保存", "metrics.json saved")).font(.caption).foregroundStyle(.secondary) }
                OutputView(text: output(detail)).frame(minHeight: 140)
            } else { OutputView(text: session.records.isEmpty ? ui("暂无验收记录。", "No verification records yet.") : ui("选择一条验收记录查看结果。", "Select a verification record to view its result.")).frame(minHeight: 140) }
            Text(ui("测试脚本须将构建、缓存和输出写在 tests/ 内。", "Test scripts must store builds, caches and output within tests/."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            await session.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                await session.refresh()
            }
        }
        .onChange(of: session.selectedID) { _ in Task { await session.readSelected() } }
        .alert(ui("取消这个验收任务？", "Cancel This Verification?"), isPresented: $cancelConfirmation) {
            Button(ui("返回", "Back"), role: .cancel) {}
            Button(ui("取消验收", "Cancel Verification"), role: .destructive) {
                if let id = session.selectedID {
                    model.cancel(Activity(title: ui("验收", "Verification"), command: "", executionID: id, sandboxIDs: [instance.id], configuration: session.configuration))
                }
            }
        }
    }
    private func output(_ detail: ExecutionSummary) -> String {
        var text = detail.result.map { String(decoding: $0.stdout, as: UTF8.self)
            + ($0.stderr.isEmpty ? "" : "\n── stderr ──\n" + String(decoding: $0.stderr, as: UTF8.self)) } ?? ui("任务在后台运行，完成后显示输出。关闭前端不会取消验收。", "The task runs in the background; output appears after completion. Closing the frontend does not cancel verification.")
        if let error = detail.error { text += "\n" + error }
        return text
    }
}
