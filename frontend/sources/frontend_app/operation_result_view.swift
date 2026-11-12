import SwiftUI
import FrontendCore

struct OperationResultView: View {
    @EnvironmentObject private var model: AppModel
    let result: OperationResult
    @ViewState private var revealing = false
    @ViewState private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(ui("操作结果", "Operation Result")).font(.title2.bold())
            ScrollView {
                Text(result.text).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled).accessibilityIdentifier("batch_result")
            }.frame(height: 320)
            if !result.reveal.bundleIDs.isEmpty {
                Text(ui("可在访达中选中仍存在的已确认容器目录。只定位，不删除；未知历史目录不在此列。", "Reveal confirmed container directories that still exist in Finder. This only selects them; unrecognized historical directories are excluded."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !message.isEmpty {
                Text(message).font(.callout).textSelection(.enabled).accessibilityIdentifier("container_reveal_message")
            }
            HStack {
                if !result.reveal.bundleIDs.isEmpty {
                    Button {
                        revealing = true; message = ""
                        Task {
                            defer { revealing = false }
                            do {
                                let reply = try await model.command(result.reveal.arguments, title: ui("在访达中显示容器", "Reveal Containers in Finder"),
                                    client: CLIClient(result.configuration), sandboxIDs: result.sandboxIDs).reply()
                                message = ([reply.finderRequested == true ? ui("已请求访达显示对应目录。", "Requested Finder to reveal the directories.") : nil].compactMap { $0 }
                                    + (reply.warnings ?? [])).joined(separator: "\n")
                            } catch { message = error.localizedDescription }
                        }
                    } label: { Label(ui("在访达中显示", "Show in Finder"), systemImage: "folder") }
                    .disabled(revealing || model.busy).accessibilityIdentifier("reveal_deleted_containers")
                }
                Spacer()
                Button(ui("好", "OK")) { model.batchResult = nil }.keyboardShortcut(.defaultAction)
                    .accessibilityLabel(ui("关闭操作结果", "Close Operation Result")).disabled(revealing)
            }
        }.padding(28).frame(width: 600)
    }
}
