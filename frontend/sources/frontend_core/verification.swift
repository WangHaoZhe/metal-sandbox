import Foundation

public struct VerificationSettings: Decodable, Equatable {
    public var testPackageSHA256: String?
    public var enabled = false
    public var timeoutSeconds: Double = 600
    public init() {}
    public func arguments(id: String) -> [String] {
        ["verification", id, "--enabled", String(enabled), "--timeout", String(timeoutSeconds)]
    }
}

public struct AutomaticVerification: Decodable, Equatable {
    public let state: String
    public let executionID: String
    public let error: String?
    public var status: String {
        ["waiting": ui("等待 Agent 及其任务结束", "Waiting for the agent and its tasks"), "submitted": ui("验收任务已提交", "Verification submitted"), "blocked": ui("自动验收受阻", "Automatic verification blocked"), "cancelled": ui("自动验收已取消", "Automatic verification cancelled")][state] ?? state
    }
}

public enum Verification {
    public static func arguments(id: String, taskFolder: URL?, timeout: Double) throws -> [String] {
        guard timeout.isFinite, timeout > 0 else { throw CLIError(ui("验收超时必须是正数秒数", "Verification timeout must be a positive number of seconds")) }
        return ["verify", id, "--timeout", String(timeout), "--detach"]
            + (taskFolder.map { ["--from", $0.path] } ?? [])
    }

    public static func status(_ execution: ExecutionSummary) -> String {
        switch execution.state {
        case "queued": return ui("排队中", "Queued")
        case "running": return ui("验收中", "Verifying")
        case "cancelled": return ui("已取消", "Cancelled")
        case "interrupted": return ui("已中断", "Interrupted")
        case "succeeded":
            return execution.error == nil && execution.result?.outcome.reason == "exited"
                && execution.result?.outcome.exitCode == 0 ? ui("通过", "Passed") : ui("结果异常", "Invalid result")
        default: return ui("未通过", "Not passed")
        }
    }
}
