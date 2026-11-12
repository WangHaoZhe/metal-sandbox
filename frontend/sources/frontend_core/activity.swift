import Foundation

public struct Activity: Identifiable, Equatable {
    public let id = UUID()
    public var date = Date()
    public let title: String
    public var command: String
    public var output = ""
    public var error = ""
    public var code: Int32?
    public var executionID: String?
    public var sandboxIDs: [String]
    public var configuration: CLIConfiguration?
    public var waiting: Bool
    public var backendState: String?
    public var hasCommandDetails = true
    public var status: String {
        if let backendState { return ["queued":ui("排队中", "Queued"), "running":ui("执行中", "Running"), "succeeded":ui("完成", "Completed"), "failed":ui("失败", "Failed"), "cancelled":ui("已取消", "Cancelled"), "interrupted":ui("已中断", "Interrupted")][backendState] ?? backendState }
        return waiting ? ui("等待结果", "Waiting for results") : code == 0 ? ui("完成", "Completed") : code == nil ? ui("提交中", "Submitting") : ui("失败", "Failed")
    }

    public init(title: String, command: String, executionID: String? = nil, sandboxIDs: [String] = [], configuration: CLIConfiguration? = nil, waiting: Bool = false) {
        self.title = title; self.command = command; self.executionID = executionID
        self.sandboxIDs = sandboxIDs; self.configuration = configuration; self.waiting = waiting
    }

    public static func merge(_ records: [ExecutionBrief], into activities: inout [Activity], configuration: CLIConfiguration) {
        for record in records {
            let index: Int
            if let found = activities.firstIndex(where: { $0.executionID == record.id && $0.configuration == configuration }) { index = found }
            else {
                var item = Activity(title: record.verification == true ? ui("验收 · tests/test.sh", "Verify · tests/test.sh") : ui("执行 · ", "Run · ") + record.program, command: record.program + ui("（读取详情后显示完整命令）", " (load details to see the full command)"), executionID: record.id, sandboxIDs: [record.instanceID], configuration: configuration)
                item.hasCommandDetails = false
                activities.append(item); index = activities.count - 1
            }
            activities[index].date = Date(timeIntervalSince1970: record.createdAt / 1000)
            activities[index].backendState = record.state
            activities[index].waiting = ["queued", "running"].contains(record.state)
            activities[index].sandboxIDs = [record.instanceID]
            if record.state == "succeeded" { activities[index].code = 0 }
        }
        activities.sort { $0.waiting == $1.waiting ? $0.date > $1.date : $0.waiting }
    }

    /// Use structured CLI arguments/replies, never names found in command output.
    public static func targets(_ arguments: [String], reply: CLIReply? = nil) -> [String] {
        guard let operation = arguments.first else { return [] }
        let instanceOperations = ["inspect", "rename", "start", "stop", "delete", "restore", "read", "write", "ls", "import", "export", "grant", "exec", "enter", "verify", "snapshot"]
        var ids: [String] = []
        if instanceOperations.contains(operation) {
            guard arguments.count > 1, arguments[1].hasPrefix("sbx-") else { return [] }
            ids.append(arguments[1])
            if let id = reply?.instance?.id { ids.append(id) }
        } else if operation == "create" {
            ids += reply?.instances?.map(\.id) ?? []
        } else if operation == "cancel", let id = reply?.execution?.instanceID {
            ids.append(id)
        }
        return Array(Set(ids)).sorted()
    }

    public static func targets(executionID: String, configuration: CLIConfiguration, in records: [Activity]) -> [String] {
        Array(Set(records.filter { $0.executionID == executionID && $0.configuration == configuration }.flatMap(\.sandboxIDs))).sorted()
    }
}

public enum ActivityFilter: Hashable {
    case all, unassigned, sandbox(String)

    public func includes(_ activity: Activity) -> Bool {
        switch self {
        case .all: return true
        case .unassigned: return activity.sandboxIDs.isEmpty
        case .sandbox(let id): return activity.sandboxIDs.contains(id)
        }
    }

    public static func sandboxIDs(in records: [Activity], currentIDs: [String]) -> [String] {
        Array(Set(currentIDs + records.flatMap(\.sandboxIDs))).sorted()
    }
}
