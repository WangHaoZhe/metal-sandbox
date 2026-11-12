import SwiftUI
import FrontendCore

@MainActor final class TrajectoryBrowser: ObservableObject {
    let instanceID: String
    let configuration: CLIConfiguration
    @Published private(set) var sessions: [TrajectorySession] = []
    @Published private(set) var selected = ""
    @Published private(set) var conversation = AgentConversation()
    private var loading = false
    @Published private(set) var error: String?
    @Published private(set) var truncated = false
    @Published var automatic = true
    @Published var autoScroll = true
    private var cursor: String?
    init(instanceID: String, configuration: CLIConfiguration) {
        self.instanceID = instanceID; self.configuration = configuration
    }
    func select(_ id: String) {
        guard id != selected else { return }
        selected = id; cursor = nil; conversation = AgentConversation(); error = nil
    }
    func refresh(app: AppModel) async {
        guard !loading, configuration == app.configuration else { return }
        loading = true
        defer { loading = false }
        let client = CLIClient(configuration)
        do {
            let result = try await client.sandbox(["trajectory", instanceID], timeout: 15).reply()
            guard configuration == app.configuration, !Task.isCancelled else { return }
            guard let list = result.trajectory?.sessions else { throw CLIError(ui("服务未返回轨迹列表。", "The service did not return a trajectory list.")) }
            let previousSession = sessions.first(where: { $0.id == selected })
            if sessions != list { sessions = list }
            let isTruncated = result.trajectory?.sessionsTruncated == true
            if truncated != isTruncated { truncated = isTruncated }
            if !list.contains(where: { $0.id == selected }) {
                select(list.first(where: { $0.sessionID == previousSession?.sessionID && $0.harness == previousSession?.harness })?.id ?? list.first?.id ?? "")
            }
            let id = selected
            guard !id.isEmpty else { if error != nil { error = nil }; return }
            // Bound each refresh, not the log size; subsequent ticks continue
            // from the cursor, and cancellation leaves already read data intact.
            for _ in 0..<8 {
                let args = ["trajectory", instanceID, "--session", id] + (cursor.map { ["--after", $0] } ?? [])
                let reply = try await client.sandbox(args, timeout: 15).reply()
                guard configuration == app.configuration, !Task.isCancelled else { return }
                guard id == selected else {
                    Task { await self.refresh(app: app) }
                    return
                }
                guard let page = reply.trajectory?.page, let harness = reply.trajectory?.harness else { throw CLIError(ui("服务未返回轨迹内容或 harness 类型。", "The service did not return trajectory content or its harness type.")) }
                if !page.data.isEmpty || page.reset { try conversation.append(page.data, harness: harness, reset: page.reset) }
                cursor = page.nextAfter
                if page.atEnd { break }
            }
            if error != nil { error = nil }
        } catch {
            if configuration == app.configuration, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

struct TrajectoryView: View {
    @EnvironmentObject private var model: AppModel
    let instance: SandboxInstance
    @ObservedObject var browser: TrajectoryBrowser
    private var available: Bool { model.filesAvailable(instance) && model.status?.trajectoryImplemented == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ui("会话", "Session"))
                Picker(ui("会话", "Session"), selection: Binding(get: { browser.selected }, set: { browser.select($0) })) {
                    if browser.sessions.isEmpty { Text(ui("暂无会话", "No Sessions")).tag("") }
                    ForEach(browser.sessions) { session in
                        Text(Date(timeIntervalSince1970: session.modifiedAt / 1000).formatted() + " · " + String(session.sessionID.prefix(8))).tag(session.id)
                    }
                }.labelsHidden().frame(maxWidth: 360, alignment: .leading)
                    .accessibilityIdentifier("trajectory_session").disabled(!available)
                Spacer()
                Toggle(ui("自动刷新", "Auto-refresh"), isOn: $browser.automatic).toggleStyle(.checkbox)
                Toggle(ui("自动滚动", "Auto-scroll"), isOn: $browser.autoScroll).toggleStyle(.checkbox)
                Button { Task { await browser.refresh(app: model) } } label: { Image(systemName: "arrow.clockwise") }
                    .help(ui("刷新轨迹", "Refresh Trajectory")).disabled(!available).accessibilityIdentifier("refresh_trajectory")
            }
            if model.compatible && model.status?.trajectoryImplemented != true { Note(text: ui("管理服务未提供轨迹读取功能。", "The manager does not provide trajectory access."), warning: true) }
            if let error = browser.error { Note(text: error, warning: true) }
            if browser.truncated { Text(ui("显示最近 256 个会话。", "Showing the latest 256 sessions.")).font(.caption).foregroundStyle(.secondary) }
            Viewport {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if browser.conversation.entries.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(ui("暂无轨迹", "No Trajectory Yet"), systemImage: "text.bubble").font(.headline)
                                    Text(ui("Agent 写入会话记录后将在这里显示。", "Conversations appear here after the agent writes session records.")).foregroundStyle(.secondary)
                                }.padding(20)
                            }
                            ForEach(browser.conversation.entries) { ConversationCard(entry: $0) }
                            Color.clear.frame(height: 1).id("trajectory_bottom")
                        }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .onChange(of: browser.conversation.entries.count) { _ in
                        if browser.autoScroll { proxy.scrollTo("trajectory_bottom", anchor: .bottom) }
                    }
                }
            }.accessibilityIdentifier("trajectory_conversation")
        }
        .task(id: available) {
            guard available else { return }
            await browser.refresh(app: model)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                if browser.automatic { await browser.refresh(app: model) }
            }
        }
        .onChange(of: browser.selected) { _ in if available { Task { await browser.refresh(app: model) } } }
    }
}

private struct ConversationCard: View {
    let entry: ConversationEntry
    @ViewState private var expanded = false
    private var folded: Bool { entry.kind == .thinking || entry.kind == .tool || entry.kind == .result || entry.text.count > 1200 }
    private var icon: String {
        switch entry.kind {
        case .user: "person.circle"
        case .assistant: "sparkles"
        case .thinking: "brain"
        case .tool: "terminal"
        case .result: "arrow.turn.down.right"
        case .error: "exclamationmark.triangle"
        case .status: "info.circle"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(entry.title, systemImage: icon).font(.headline).foregroundStyle(entry.kind == .error ? Color.red : Color.accentColor)
                Spacer()
                if let time = entry.timestamp { Text(time).font(.caption).foregroundStyle(.secondary) }
                if folded { Button(expanded ? ui("收起", "Collapse") : ui("展开", "Expand")) { expanded.toggle() }.buttonStyle(.borderless) }
            }
            if !entry.text.isEmpty {
                Text(folded && !expanded ? String(entry.text.prefix(300)) : entry.text)
                    .font(entry.kind == .tool || entry.kind == .result ? .system(.callout, design: .monospaced) : .body)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(folded && !expanded ? 4 : nil)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(entry.kind == .user ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
