import Foundation

public enum SandboxBatchAction {
    case stop, delete
    public var title: String { self == .stop ? ui("停止", "Stop") : ui("永久删除", "Permanently Delete") }
    public func arguments(_ id: String) -> [String] {
        self == .stop ? ["stop", id] : ["delete", id, "--confirm"]
    }
}

/// Immutable, explicitly confirmed targets. A batch is not a transaction:
/// attempt every target once, collecting failures without retry or rollback.
public struct SandboxBatch: Identifiable {
    public let id = UUID()
    public let action: SandboxBatchAction
    public let ids: [String]
    public init(action: SandboxBatchAction, ids: [String]) {
        self.action = action
        var seen = Set<String>()
        self.ids = ids.filter { seen.insert($0).inserted }
    }

    public func blockingReason(instances: [SandboxInstance], status: ServiceStatus?) -> String? {
        guard !ids.isEmpty else { return ui("请选择 Sandbox。", "Select a sandbox.") }
        guard let status else { return ui("服务未连接，请刷新后重试。", "The service is disconnected. Refresh and try again.") }
        if action == .delete {
            guard status.permanentDeletionImplemented == true else { return ui("当前服务不支持永久删除。", "This service does not support permanent deletion.") }
        }
        for id in ids {
            guard let item = instances.first(where: { $0.id == id }) else { return ui("实例已不在列表中：\(id)", "Instance no longer listed: \(id)") }
            guard action == .stop ? item.canStop : item.canDelete else {
                return ui("\(id)（\(item.displayState)）不能\(action.title)。", "Cannot \(action.title.lowercased()) \(id) (\(item.displayState)). ") + (action == .delete ? ui("请先停止活动实例。", "Stop active instances first.") : ui("请只选择可停止的实例。", "Select instances that can be stopped."))
            }
        }
        return nil
    }

    @MainActor public func execute(command: (String, [String]) async throws -> Void) async -> SandboxBatchResult {
        var completed: [String] = []
        var issues: [SandboxBatchIssue] = []
        for id in ids {
            let args = action.arguments(id)
            do { try await command(id, args); completed.append(id) }
            catch {
                issues.append(SandboxBatchIssue(id: id, error: error.localizedDescription,
                                               reportedFailure: (error as? CLIError)?.reportedFailure == true))
            }
        }
        return SandboxBatchResult(completed: completed, issues: issues)
    }
}

public struct SandboxBatchIssue {
    public let id: String
    public let error: String
    /// The CLI returned an error; this does not imply earlier side effects were rolled back.
    public let reportedFailure: Bool
}

public struct SandboxBatchResult {
    public let completed: [String]
    public let issues: [SandboxBatchIssue]
    public func summary(action: SandboxBatchAction) -> String {
        var text = ui("已\(action.title) \(completed.count) 个 Sandbox。", "\(action == .stop ? "Stopped" : "Permanently deleted") \(completed.count) sandboxes.")
        for (label, items) in [(ui("失败", "Failed"), issues.filter(\.reportedFailure)), (ui("结果未知", "Unknown results"), issues.filter { !$0.reportedFailure })] where !items.isEmpty {
            text += ui("\n\n\(label)：\(items.count) 个。", "\n\n\(label): \(items.count).")
            for item in items { text += "\n\(item.id)\n\(item.error)" }
        }
        if !issues.isEmpty {
            text += ui("\n\n已继续处理其余实例；每项仅尝试一次，不自动重试或回滚。失败可能已产生部分变更，结果未知不代表未执行，请刷新检查。", "\n\nRemaining instances were processed once without automatic retries or rollback. Failed operations may have made partial changes; unknown results may have executed. Refresh to check.")
        }
        return text
    }
}
