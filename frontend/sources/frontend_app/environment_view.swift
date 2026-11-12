import SwiftUI
import FrontendCore

struct EnvironmentEditor: View {
    @Binding var rows: [EnvironmentRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ui("键名", "Key")).frame(width: 170, alignment: .leading)
                Text(ui("键值", "Value")).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption).foregroundStyle(.secondary)
            Viewport {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach($rows) { $row in
                            HStack {
                                TextField("KEY", text: $row.key).frame(width: 170).accessibilityLabel(ui("环境变量键名", "Environment Variable Key"))
                                TextField(ui("值", "Value"), text: $row.value).privacySensitive().accessibilityLabel(ui("环境变量键值", "Environment Variable Value"))
                                Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help(ui("移除变量", "Remove Variable"))
                            }.textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
                        }
                    }.padding(2)
                }
            }.frame(height: 150)
            Button(ui("添加变量", "Add Variable"), systemImage: "plus") { rows.append(EnvironmentRow()) }.accessibilityIdentifier("add_environment_variable")
            Text(ui("值按原样传入，不执行 shell 展开。保存在实例私有配置，不写入题包或工作区快照；实例内程序可读取这些值。", "Values are passed literally, without shell expansion. They are stored in private instance configuration, outside task packages and workspace snapshots; programs in the instance can read them."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor final class EnvironmentSession: ObservableObject, DraftReloading {
    let id: String
    let configuration: CLIConfiguration
    @Published var rows: [EnvironmentRow] = []
    @Published var saved: [String: String] = [:]
    @Published var loaded = false
    @Published var loading = false
    @Published var error: String?
    var pendingReload: Bool?
    init(id: String, configuration: CLIConfiguration) { self.id = id; self.configuration = configuration }
    var dirty: Bool { (try? EnvironmentDocument.values(rows)) != saved }
    func readDraft() async throws -> [String: String] { try await CLIClient(configuration).environment(id: id) }
    func applyDraft(_ value: [String: String], baseline: [String: String], preservingDraft: Bool) {
        let current = try? EnvironmentDocument.values(rows)
        if (!preservingDraft || current == baseline) && current != value { rows = EnvironmentDocument.rows(value) }
    }
    func save(app: AppModel) async throws {
        guard app.configuration == configuration else { throw CLIError(ui("连接设置已改变，请重新打开配置页。", "Connection settings changed. Reopen the configuration page.")) }
        let values = try EnvironmentDocument.values(rows)
        let activity = app.log(Activity(title: ui("保存环境变量", "Save Environment Variables"), command: "sandboxctl env " + id + " --from <private-configuration-file>", sandboxIDs: [id], configuration: configuration))
        do {
            try await CLIClient(configuration).replaceEnvironment(id: id, values: values)
            saved = values; loaded = true; error = nil
            app.update(activity) { $0.code = 0; $0.output = ui("环境变量已保存，对新提交的命令生效。", "Environment variables saved; they apply to newly submitted commands.") }
        } catch {
            app.update(activity) { $0.code = 1; $0.error = error.localizedDescription }; throw error
        }
    }
}

struct InstanceEnvironmentView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: EnvironmentSession
    @ViewState private var expanded = false
    private var canRead: Bool { model.compatible && model.status?.environmentImplemented == true && !model.busy }
    private var validationError: String? {
        do { _ = try EnvironmentDocument.values(session.rows); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        GroupBox {
            DisclosureGroup(ui("环境变量", "Environment Variables"), isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    if model.status?.environmentImplemented == true {
                        EnvironmentEditor(rows: $session.rows).disabled(!session.loaded || session.loading || !model.canMutate)
                        if let error = session.error ?? validationError { Text(error).foregroundStyle(.red).font(.caption) }
                        HStack {
                            Button(ui("重新读取", "Reload")) { Task { await session.reload(app: model) } }.disabled(session.loading || session.dirty || !model.canMutate)
                            Button(ui("保存环境变量", "Save Environment Variables")) { model.perform { try await session.save(app: model) } }
                                .disabled(!session.loaded || session.loading || !session.dirty || validationError != nil || !model.canMutate)
                        }
                        Text(ui("停止的实例也可修改。已运行的进程不变；Agent 需重新启动才能读取新值。", "Stopped instances can also be edited. Running processes retain their environment; restart the Agent to use new values."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text(ui("管理服务未提供环境变量配置。", "The management service does not support environment configuration.")).foregroundStyle(.secondary) }
                }.padding(.top, 10)
            }.padding(8)
        }
        .task(id: expanded && canRead) {
            if expanded && canRead { await session.reload(app: model, preservingDraft: true) }
        }
    }
}
