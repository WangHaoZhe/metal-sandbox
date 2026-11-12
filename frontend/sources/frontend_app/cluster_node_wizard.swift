import SwiftUI
import FrontendCore

struct ClusterNodeWizard: View {
    @Environment(\.dismiss) private var dismiss
    let client: CLIClient
    let reservedIDs: [String]
    var savesConfiguration = false
    var allowsRestart = false
    let onAdd: (ClusterNodeConfiguration, Bool) async throws -> Void
    @ViewState private var name = ""
    @ViewState private var host = ""
    @ViewState private var user = ""
    @ViewState private var port = "22"
    @ViewState private var cliPath = "/Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl"
    @ViewState private var stateDirectory = ""
    @ViewState private var limit = ""
    @ViewState private var schedulingPool = "default"
    @ViewState private var crossNodeScheduling = true
    @ViewState private var password = ""
    @ViewState private var scan: ClusterSSHScan?
    @ViewState private var connection: ClusterSSHConnection?
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var restart = true

    private var step: Int { connection != nil ? 3 : scan != nil ? 2 : 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(ui("添加节点", "Add Node")).font(.title2.bold())
                Spacer()
                Text("\(step) / 3 · \([ui("连接信息", "Connection"), ui("SSH 认证", "SSH Authentication"), ui("确认添加", "Confirm Addition")][step - 1])").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let connection {
                        Label(ui("SSH 密钥认证与远端服务检查通过", "SSH key authentication and remote service checks passed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("\(connection.node.id) · \(connection.node.sshDestination)")
                        HostEnvironmentView(status: connection.status)
                        if savesConfiguration {
                            Toggle(ui("立即重新启动管理服务", "Restart the Manager Now"), isOn: $restart).disabled(!allowsRestart)
                                .accessibilityIdentifier("cluster_wizard_restart")
                            Text(allowsRestart ? ui("重新启动后使用新配置。", "The new configuration takes effect after restart.") : ui("当前存在活动实例或待完成命令，配置将在下次启动服务时生效。", "Instances or commands are active; settings take effect at the next service start."))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(ui("添加后点击连接设置中的“保存并应用”，保存节点配置。", "After adding the node, click Save and Apply in Connection Settings to save the configuration.")).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let scan {
                        Text(ui("请核对 \(host):\(port) 的主机指纹", "Verify the Host Fingerprint for \(host):\(port)")).font(.headline)
                        Text(scan.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .accessibilityIdentifier("cluster_wizard_fingerprint")
                        Text(ui("可在从节点终端运行 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 核对。", "On the worker, run ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub to verify it."))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        SecureField(ui("\(user) 的登录密码", "Login Password for \(user)"), text: $password).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("cluster_wizard_password")
                        Text(ui("连接后将本机 ~/.ssh/metal_sandbox_cluster 的公钥加入远端 authorized_keys，供后续自动连接使用。已有该密钥认证时密码可留空。密码仅用于本次连接。", "Adds the public key from ~/.ssh/metal_sandbox_cluster to the remote authorized_keys for future connections. Leave the password empty if this key already works. The password is used only for this connection."))
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(ui("从节点需要开启“远程登录”，并运行同版本的 Metal Sandbox 服务。", "Enable Remote Login on the worker and run the same version of the Metal Sandbox service."))
                            .foregroundStyle(.secondary)
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                            field(ui("节点名称", "Node Name"), text: $name, id: "cluster_wizard_name")
                            field(ui("主机地址", "Host Address"), text: $host, id: "cluster_wizard_host")
                            field(ui("登录用户名", "Login Username"), text: $user, id: "cluster_wizard_user")
                        }
                        DisclosureGroup(ui("高级选项", "Advanced Options")) {
                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                                field(ui("SSH 端口", "SSH Port"), text: $port, id: "cluster_wizard_port")
                                field(ui("远端 CLI 路径", "Remote CLI Path"), text: $cliPath, id: "cluster_wizard_cli")
                                field(ui("远端状态目录", "Remote State Directory"), text: $stateDirectory, id: "cluster_wizard_state", prompt: "/Users/<user>/Library/Application Support/MetalSandbox/native")
                                field(ui("最大并发实例数", "Maximum Concurrent Instances"), text: $limit, id: "cluster_wizard_limit", prompt: ui("跟随从节点", "Follow Worker"))
                                field(ui("调度池", "Scheduling Pool"), text: $schedulingPool, id: "cluster_wizard_pool", prompt: "default")
                            }.padding(.top, 12)
                            Toggle(ui("允许跨节点调度", "Allow Cross-node Scheduling"), isOn: $crossNodeScheduling)
                                .accessibilityIdentifier("cluster_wizard_cross_node")
                        }
                    }
                    if let error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("cluster_wizard_error")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            HStack {
                Button(ui("取消", "Cancel")) { password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cluster_wizard_cancel")
                if step > 1 {
                    Button(ui("上一步", "Previous")) { error = nil; password = ""; if connection != nil { connection = nil } else { scan = nil } }
                        .accessibilityIdentifier("cluster_wizard_back")
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(step == 1 ? ui("连接", "Connect") : step == 2 ? ui("确认指纹并连接", "Verify Fingerprint and Connect") : savesConfiguration && restart ? ui("保存并重新启动", "Save and Restart") : ui("添加节点", "Add Node")) {
                    Task { await advance() }
                }.primaryAction().keyboardShortcut(.defaultAction).accessibilityIdentifier("cluster_wizard_next")
            }
        }.padding(24).frame(width: 610, height: 520).disabled(busy)
            .interactiveDismissDisabled(busy)
            .onAppear { restart = allowsRestart }
            .onChange(of: allowsRestart) { if !$0 { restart = false } }
            .onDisappear { password = "" }
    }
    private func field(_ title: String, text: Binding<String>, id: String, prompt: String = "") -> some View {
        GridRow {
            Text(title).gridColumnAlignment(.trailing)
            TextField(title, text: text, prompt: Text(prompt)).labelsHidden().textFieldStyle(.roundedBorder).accessibilityIdentifier(id)
        }
    }
    private func request() throws -> ClusterSSHRequest {
        guard !name.isEmpty, !reservedIDs.contains(name) else { throw CLIError(ui("请填写未被使用的节点名称。", "Enter an unused node name.")) }
        guard let port = Int(port), (1...65535).contains(port) else { throw CLIError(ui("SSH 端口需要填写 1–65535。", "SSH port must be between 1 and 65535.")) }
        var maximum: Int?
        if !limit.isEmpty {
            guard let value = Int(limit), value >= 0 else { throw CLIError(ui("最大并发实例数需要填写非负整数。", "Maximum concurrent instances must be a nonnegative integer.")) }
            maximum = value
        }
        var node = ClusterNodeConfiguration(id: name, sshDestination: user + "@" + host, cliPath: cliPath,
            stateDirectory: stateDirectory.isEmpty ? "/Users/\(user)/Library/Application Support/MetalSandbox/native" : stateDirectory,
            maxConcurrentInstances: maximum)
        let pool = schedulingPool.trimmingCharacters(in: .whitespacesAndNewlines)
        node.schedulingPool = pool.isEmpty || pool == "default" ? nil : pool
        node.crossNodeSchedulingEnabled = crossNodeScheduling ? nil : false
        return ClusterSSHRequest(host: host, user: user, port: port, node: node, hostKeys: scan?.hostKeys)
    }
    private func advance() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if let connection {
                try await onAdd(connection.node, savesConfiguration && restart)
                dismiss()
            } else if scan != nil {
                var input = try request(); input.password = password; password = ""
                connection = try await client.connectClusterSSH(input)
            } else { scan = try await client.scanClusterSSH(request()) }
        } catch { self.error = error.localizedDescription }
    }
}

struct OverviewAddNodeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var document: ClusterConfigurationDocument?
    @ViewState private var configuration: CLIConfiguration?
    @ViewState private var error: String?
    var body: some View {
        Group {
            if let document, let configuration {
                ClusterNodeWizard(client: CLIClient(configuration), reservedIDs: [document.localNodeID] + document.nodes.map(\.id),
                                  savesConfiguration: true, allowsRestart: model.status.map { $0.activeInstances == 0 && $0.pendingExecutions == 0 } ?? false) { node, restart in
                    guard model.configuration == configuration else { throw CLIError(ui("连接设置已改变，请重新打开添加节点向导。", "Connection settings changed; reopen the Add Node wizard.")) }
                    if restart {
                        let status = try await model.client.sandbox(["status"]).reply().status
                        guard status?.activeInstances == 0, status?.pendingExecutions == 0 else { throw CLIError(ui("服务已有活动实例或任务，请关闭立即重新启动选项后保存。", "Instances or tasks are active. Disable immediate restart before saving.")) }
                    }
                    var updated = document; updated.nodes.append(node)
                    let path = configuration.clusterConfig ?? NSHomeDirectory() + "/Library/Application Support/MetalSandboxUI/cluster.json"
                    try await model.client.saveClusterConfiguration(updated, at: path)
                    if restart { _ = try await model.command(["shutdown", "--if-idle"], title: ui("重新启动以添加节点", "Restart to Add Node")) }
                    model.clusterConfig = path
                    model.saveSettings()
                    if restart { try await model.startServiceAndWait(); await model.refresh() }
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Text(ui("添加节点", "Add Node")).font(.title2.bold())
                    if let error { Text(error).foregroundStyle(.red) }
                    else { ProgressView(ui("读取节点配置…", "Reading Node Configuration…")) }
                    Button(ui("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                }.padding(24).frame(width: 610, height: 520)
            }
        }.task {
            let current = model.configuration
            do {
                if let path = current.clusterConfig { document = try await model.client.readClusterConfiguration(at: path) }
                else { document = ClusterConfigurationDocument(localNodeID: model.status?.nodeID ?? "manager", sharedRoot: model.status?.sharedRoot,
                    maxConcurrentInstances: model.status?.maxConcurrentInstances ?? model.maxConcurrentInstances) }
                configuration = current
            } catch { self.error = error.localizedDescription }
        }
    }
}
