import SwiftUI
import QuickLookUI
import FrontendCore

@MainActor final class WorkspaceBrowser: ObservableObject {
    let instanceID: String
    let configuration: CLIConfiguration
    @Published var expanded: Set<String> = []
    @Published private(set) var directories: [String: [WorkspaceEntry]] = [:]
    @Published private(set) var nextAfter: [String: String] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var selected: WorkspaceEntry?
    @Published private(set) var preview: WorkspacePreview?
    @Published private(set) var loadingFile = false
    @Published private(set) var previewMessage: String?
    private var pendingPreview: WorkspacePreview?
    private var directoryGeneration = UUID()
    private var fileGeneration = UUID()
    private var readPending = false
    init(instanceID: String, configuration: CLIConfiguration) {
        self.instanceID = instanceID; self.configuration = configuration
    }
    func loadDirectory(_ path: String, app: AppModel, more: Bool = false) async {
        guard app.configuration == configuration, !loading.contains(path) else { return }
        let after = more ? nextAfter[path] : nil
        if more && after == nil { return }
        let generation = directoryGeneration
        loading.insert(path); errors[path] = nil
        defer { if generation == directoryGeneration { loading.remove(path) } }
        do {
            var args = ["ls", instanceID, "--", path]
            if let after { args += ["--after", after] }
            let reply = try await app.command(args, title: ui("列出工作区目录", "List Workspace Directory"), client: CLIClient(configuration)).reply()
            guard let page = reply.directory else { throw CLIError(ui("CLI 未返回目录信息；请检查服务版本。", "The CLI did not return directory information; check the service version.")) }
            try page.validate(requestedPath: path, after: after)
            guard app.configuration == configuration, generation == directoryGeneration else { return }
            directories[path] = (more ? directories[path] ?? [] : []) + page.entries
            nextAfter[path] = page.nextAfter
            if let selected, let current = page.entries.first(where: { $0.path == selected.path }) { self.selected = current }
        } catch {
            if generation == directoryGeneration { errors[path] = error.localizedDescription }
        }
    }
    func refresh(app: AppModel) async {
        directoryGeneration = UUID(); loading = []; errors = [:]
        let generation = directoryGeneration
        await loadDirectory(".", app: app)
        var paths = expanded
        if let selected, let slash = selected.path.lastIndex(of: "/") { paths.insert(String(selected.path[..<slash])) }
        for path in paths.sorted() {
            guard generation == directoryGeneration, !Task.isCancelled else { return }
            await loadDirectory(path, app: app)
        }
        guard generation == directoryGeneration, !Task.isCancelled else { return }
        if let entry = selected {
            let parent = entry.path.lastIndex(of: "/").map { String(entry.path[..<$0]) } ?? "."
            if errors[parent] == nil, let children = directories[parent], nextAfter[parent] == nil,
               !children.contains(where: { $0.path == entry.path }) {
                selected = nil; closePreview(); previewMessage = ui("所选条目已不存在。", "The selected item no longer exists."); return
            }
            if entry.kind == .file { await read(app: app) }
        }
    }
    func open(_ entry: WorkspaceEntry, app: AppModel) async {
        guard !loadingFile else { return }
        selected = entry; preview = nil; previewMessage = nil
        if entry.kind != .file {
            previewMessage = entry.kind == .directory ? nil : ui("仅显示元数据，不预览符号链接或特殊文件。", "Metadata only; symbolic links and special files are not previewed.")
        } else { await read(app: app) }
    }
    func read(app: AppModel) async {
        guard let entry = selected, entry.kind == .file,
              app.configuration == configuration else { return }
        guard !loadingFile else { readPending = true; return }
        let generation = UUID(); fileGeneration = generation
        loadingFile = true; previewMessage = nil
        defer {
            pendingPreview = nil; loadingFile = false
            if readPending { readPending = false; Task { await self.read(app: app) } }
        }
        do {
            let copy = try WorkspacePreview(name: entry.name)
            pendingPreview = copy
            _ = try await app.command(["read", instanceID, entry.path, "--out", copy.file.path], title: ui("预览工作区文件", "Preview Workspace File"), client: CLIClient(configuration))
            guard generation == fileGeneration, selected?.path == entry.path, app.configuration == configuration, !Task.isCancelled else { return }
            try copy.prepare()
            preview = copy
        } catch {
            if generation == fileGeneration, app.configuration == configuration, !Task.isCancelled {
                preview?.close(); preview = nil
                previewMessage = ui("读取失败：", "Read failed: ") + error.localizedDescription
            }
        }
    }
    func closePreview() {
        fileGeneration = UUID()
        preview?.close(); pendingPreview?.close()
        preview = nil
    }
}

struct SystemFilePreview: NSViewRepresentable {
    let preview: WorkspacePreview
    final class Coordinator { var preview: WorkspacePreview? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.setAccessibilityIdentifier("workspace_system_preview")
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.preview !== preview else { return }
        context.coordinator.preview = preview
        view.previewItem = preview.file as NSURL
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
        coordinator.preview = nil
    }
}

struct WorkspaceTree: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var browser: WorkspaceBrowser
    let path: String
    let choose: (WorkspaceEntry) -> Void
    var body: some View {
        ForEach(browser.directories[path] ?? []) { entry in
            if entry.kind == .directory {
                DisclosureGroup(isExpanded: Binding(get: { browser.expanded.contains(entry.path) }, set: { expanded in
                    if expanded {
                        browser.expanded.insert(entry.path)
                        Task { await browser.loadDirectory(entry.path, app: model) }
                    } else { browser.expanded.remove(entry.path) }
                })) {
                    WorkspaceTree(browser: browser, path: entry.path, choose: choose)
                } label: {
                    Button { choose(entry) } label: {
                        Label(entry.name, systemImage: "folder")
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(entry.name).accessibilityIdentifier("workspace_entry_" + entry.path)
                        .contextMenu {
                            Button(ui("在访达中显示", "Reveal in Finder")) { model.revealWorkspace(browser.instanceID, path: entry.path, configuration: browser.configuration) }
                                .disabled(!model.canMutate || model.status?.workspaceRevealImplemented != true)
                        }
                }
            } else {
                Button { choose(entry) } label: {
                    Label(entry.name, systemImage: entry.kind == .symlink ? "link" : entry.kind == .file ? "doc" : "questionmark.square")
                        .foregroundStyle(browser.selected?.path == entry.path ? Color.accentColor : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(entry.name).accessibilityIdentifier("workspace_entry_" + entry.path)
                    .contextMenu {
                        if entry.kind == .file {
                            Button(ui("在访达中显示", "Reveal in Finder")) { model.revealWorkspace(browser.instanceID, path: entry.path, configuration: browser.configuration) }
                                .disabled(!model.canMutate || model.status?.workspaceRevealImplemented != true)
                        }
                    }
            }
        }
        if browser.loading.contains(path) { ProgressView().controlSize(.small) }
        if let error = browser.errors[path] {
            VStack(alignment: .leading) {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button(ui("重试", "Retry")) { Task { await browser.loadDirectory(path, app: model, more: browser.nextAfter[path] != nil) } }
            }
        } else if browser.directories[path]?.isEmpty == true { Text(ui("空文件夹", "Empty Folder")).font(.caption).foregroundStyle(.secondary) }
        if browser.nextAfter[path] != nil {
            Button(ui("加载更多…", "Load More…")) { Task { await browser.loadDirectory(path, app: model, more: true) } }
                .disabled(browser.loading.contains(path))
        }
    }
}
