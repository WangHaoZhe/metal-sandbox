import SwiftUI
import AppKit
import FrontendCore

// Explicitly name the standard property-wrapper type: the macOS 27 CLT SDK
// also exports a same-name State macro whose plugin ships only with Xcode.
typealias ViewState<Value> = SwiftUI.State<Value>

final class AppDelegate: NSObject, NSApplicationDelegate {
    var reopenMainWindow: (() -> Void)?
    var closeUI: (() -> Void)?
    private var searchClickMonitor: Any?
    func applicationWillTerminate(_ notification: Notification) {
        closeUI?()
        if let searchClickMonitor { NSEvent.removeMonitor(searchClickMonitor) }
        NotificationCenter.default.removeObserver(self)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(self, selector: #selector(configureSearch(_:)), name: NSWindow.didUpdateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(endSearch(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        searchClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let field = self?.searchItem(in: event.window)?.searchField, field.currentEditor() != nil,
               !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                event.window?.makeFirstResponder(nil)
            }
            return event
        }
    }
    private func searchItem(in window: NSWindow?) -> NSSearchToolbarItem? {
        window?.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first
    }
    @objc private func configureSearch(_ notification: Notification) {
        guard let item = searchItem(in: notification.object as? NSWindow),
              !item.searchField.constraints.contains(where: { $0.identifier == "metal_sandbox_search_width" }) else { return }
        item.preferredWidthForSearchField = 240
        let width = item.searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
        width.identifier = "metal_sandbox_search_width"
        width.isActive = true
    }
    @objc private func endSearch(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              searchItem(in: window)?.searchField.currentEditor() != nil else { return }
        window.makeFirstResponder(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let reopenMainWindow { reopenMainWindow(); return false }
        return true
    }
}

@main struct MetalSandboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Metal Sandbox", id: "main") {
            RootView(appDelegate: delegate).environmentObject(model).environment(\.locale, model.language.locale).frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button(ui("刷新 Sandbox", "Refresh Sandboxes")) { Task { await model.refresh() } }.keyboardShortcut("r")
                Button(ui("操作记录", "Activity")) { model.page = .activity }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        Settings { SettingsView().environmentObject(model).environment(\.locale, model.language.locale).frame(width: 640, height: 470) }
    }
}

extension View {
    /// Let the window's native background continue beneath its toolbar rather
    /// than drawing a separate opaque rectangle over the detail column.
    @ViewBuilder func transparentWindowToolbar() -> some View {
        if #available(macOS 15.0, *) { self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar) }
        else { self.toolbarBackground(.hidden, for: .windowToolbar) }
    }

    @ViewBuilder func primaryAction() -> some View {
        if #available(macOS 26.0, *) { self.buttonStyle(.glassProminent) }
        else { self.buttonStyle(.borderedProminent) }
    }

    @ViewBuilder func toolbarAction() -> some View {
        if #available(macOS 26.0, *) {
            self.labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
        } else if #available(macOS 14.0, *) {
            self.labelStyle(.iconOnly).buttonStyle(.bordered).buttonBorderShape(.circle)
        } else {
            self.labelStyle(.iconOnly).buttonStyle(.bordered)
        }
    }

}

extension ToolbarContent {
    @ToolbarContentBuilder func separateToolbarButtons() -> some ToolbarContent {
        if #available(macOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Note: View {
    let text: String
    var warning = false
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: warning ? "exclamationmark.triangle" : "info.circle") }
            .font(.callout).foregroundStyle(warning ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OutputView: View {
    let text: String
    var accessibilityIdentifier = "command_output"
    var accessibilityLabel = ui("命令输出", "Command Output")
    var body: some View {
        Viewport {
            TerminalOutputView(text: text.isEmpty ? ui("暂无输出", "No output yet") : String(text.prefix(262144)) + (text.count > 262144 ? ui("\n[界面仅展示前 256 Ki 字符]", "\n[Only the first 256 Ki characters are displayed]") : ""),
                               autoScroll: false, accessibilityIdentifier: accessibilityIdentifier, accessibilityLabel: accessibilityLabel)
        }.background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

/// A scroll/editor pane must consume its allocated viewport, not propagate its
/// document's ideal size into NavigationSplitView's AppKit hosting layout.
struct Viewport<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            content().frame(width: max(0, geometry.size.width), height: max(0, geometry.size.height), alignment: .topLeading)
        }.clipped()
    }
}

@MainActor enum Panels {
    static func taskPackage() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = ui("选择包含 agent/instruction.md 和 agent/setup.sh 的题包文件夹。", "Select a task folder containing agent/instruction.md and agent/setup.sh.")
        panel.prompt = ui("选择题目文件夹", "Select Task Folder")
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func openFile() -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func directory() -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func save(name: String, message: String = "") -> URL? {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.message = message; panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
