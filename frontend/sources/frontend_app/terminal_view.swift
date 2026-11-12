import SwiftUI
import FrontendCore

@MainActor final class TerminalSession: ObservableObject {
    let instanceID: String
    @Published private(set) var connected = false
    @Published private(set) var output = ""
    @Published var input = ""
    @Published var cwd = ""
    @Published var timeout = 30.0
    @Published var showAdvanced = false
    @Published var autoScroll = true
    private var console: CLIConsole?
    private var generation: UUID?
    private var bytes = Data()
    private var truncated = false
    private(set) var started = false
    init(instanceID: String) { self.instanceID = instanceID }

    func start(client: CLIClient) {
        guard !connected else { return }
        started = true
        let generation = UUID(); self.generation = generation
        append("\n— sandbox enter \(instanceID) —\n")
        do {
            console = try client.enter(instanceID) { [weak self] event in
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    switch event {
                    case .output(let bytes): self.append(bytes)
                    case .error(let message): self.append("\n[\(message)]\n")
                    case .exited(let code):
                        self.connected = false; self.console = nil
                        self.append(ui("\n[控制台已退出，退出码 \(code)；不会停止 Sandbox。]\n", "\n[Console exited with code \(code); the sandbox remains running.]\n"))
                    }
                }
            }
            connected = true
        } catch { append(ui("[无法启动控制台：\(error.localizedDescription)]\n", "[Cannot start console: \(error.localizedDescription)]\n")) }
    }
    func send() {
        guard let console, connected, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try console.send(ConsoleCommand(line: input, cwd: cwd, timeout: timeout))
            append("\n> \(input)\n"); input = ""
        } catch { append("\n[\(error.localizedDescription)]\n") }
    }
    func disconnect() {
        guard console != nil else { return }
        generation = nil; console?.close(); console = nil; connected = false
        append(ui("\n[已断开控制台；已提交的命令可能继续运行，不会停止 Sandbox。]\n", "\n[Console disconnected; submitted commands may continue and the sandbox remains running.]\n"))
    }
    func clear() { bytes = Data(); truncated = false; output = "" }
    func use(_ template: ConsoleTemplate) { input = template.line }
    private func append(_ text: String) { append(Data(text.utf8)) }
    private func append(_ data: Data) {
        bytes.append(data)
        let limit = 256 * 1024
        if bytes.count > limit { bytes.removeFirst(bytes.count - limit); truncated = true }
        output = (truncated ? ui("[仅保留最近 256 KiB 控制台内容]\n", "[Only the latest 256 KiB of console output is retained]\n") : "") + String(decoding: bytes, as: UTF8.self)
    }
    deinit { console?.close() }
}

struct TerminalView: View {
    @EnvironmentObject private var model: AppModel
    let instance: SandboxInstance
    @ObservedObject var session: TerminalSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(session.connected ? ui("控制台已启动", "Console Connected") : ui("控制台未连接", "Console Disconnected"), systemImage: "terminal")
                Spacer()
                Button(ui("在终端中打开", "Open in Terminal")) { model.openTerminal(instance.id) }
                    .disabled(!instance.isActive || !model.canCreate)
                    .accessibilityIdentifier("open_system_terminal")
                    .help(ui("在 macOS 终端中调用 sandbox enter，打开独立控制台会话。", "Open a separate console using sandbox enter in macOS Terminal."))
            }
            HStack {
                Toggle(ui("自动滚动", "Auto-scroll"), isOn: $session.autoScroll).toggleStyle(.checkbox)
                    .accessibilityIdentifier("terminal_auto_scroll")
                Spacer()
                Button(ui("连接", "Connect")) { session.start(client: model.client) }
                    .disabled(session.connected || !instance.isActive || !model.canCreate)
                    .accessibilityLabel(ui("连接终端", "Connect Terminal")).accessibilityIdentifier("connect_terminal")
                Button(ui("断开", "Disconnect")) { session.disconnect() }.disabled(!session.connected)
                    .accessibilityLabel(ui("断开终端", "Disconnect Terminal")).accessibilityIdentifier("disconnect_terminal")
                Button(ui("清屏", "Clear")) { session.clear() }.accessibilityLabel(ui("清屏", "Clear")).accessibilityIdentifier("clear_terminal")
                Button(ui("操作记录", "Activity")) { model.page = .activity }
            }
            Viewport {
                TerminalOutputView(text: session.output.isEmpty ? ui("输入命令后按回车。", "Type a command and press Return.") : session.output, autoScroll: session.autoScroll)
            }.frame(minHeight: 140)
                .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            HStack {
                Text(">").font(.system(.body, design: .monospaced))
                TextField(ui("输入一行命令，回车发送", "Enter one command line; Return sends it"), text: $session.input)
                    .font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(ui("终端命令", "Terminal Command")).accessibilityIdentifier("terminal_input")
                    .onSubmit { session.send() }
                Button(ui("发送", "Send")) { session.send() }.primaryAction().accessibilityLabel(ui("发送命令", "Send Command")).accessibilityIdentifier("send_terminal")
                    .keyboardShortcut(.return, modifiers: .command)
            }.disabled(!session.connected || !instance.isActive || !model.canCreate)
            DisclosureGroup(ui("高级选项", "Advanced Options"), isExpanded: $session.showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField(ui("工作目录：留空沿用当前目录", "Working Directory (empty keeps current)"), text: $session.cwd)
                            .textFieldStyle(.roundedBorder).accessibilityLabel(ui("工作目录", "Working Directory")).accessibilityIdentifier("terminal_cwd")
                        Text(ui("超时（秒）", "Timeout (seconds)"))
                        TextField(ui("秒", "Seconds"), value: $session.timeout, format: .number)
                            .frame(width: 80).textFieldStyle(.roundedBorder)
                            .accessibilityLabel(ui("超时秒数", "Timeout in Seconds")).accessibilityIdentifier("terminal_timeout")
                        Menu(ui("命令模板", "Command Templates")) {
                            ForEach(ConsoleTemplate.allCases, id: \.self) { template in
                                Button(template.title) { session.use(template) }
                            }
                        }.id(model.language).accessibilityIdentifier("terminal_templates")
                    }
                    Text(ui("目录相对于 workspace；留空跟随 cd，填写后仅覆盖每条命令的工作目录。模板只填入命令，不自动执行。", "Directories are workspace-relative. Leave empty to follow cd, or override each command's directory. Templates fill the input without executing."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("terminal_advanced")
            Note(text: ui("cd 保留当前目录，exit 退出控制台。结果在命令结束后返回；不是 PTY，不支持 vim/top、交互 stdin 或跨命令 shell 变量。", "cd preserves the current directory; exit closes the console. Results arrive after completion. This is not a PTY: vim/top, interactive stdin and shell variables across commands are unsupported."))
        }
        .task(id: instance.isActive && model.canCreate) {
            if !session.started && instance.isActive && model.canCreate { session.start(client: model.client) }
        }
    }
}
