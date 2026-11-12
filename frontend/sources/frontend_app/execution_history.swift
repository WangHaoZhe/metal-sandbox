import Foundation
import FrontendCore

/// Shared paging and refresh coalescing for global activity and per-instance
/// verification. Only changed snapshots are published to the owning view model.
@MainActor final class ExecutionHistoryReader {
    struct Snapshot: Equatable {
        var records: [ExecutionBrief] = []
        var cursor: String?
        var loadingMore = false
        var error: String?
    }
    private(set) var snapshot = Snapshot()
    private let configuration: CLIConfiguration
    private let instanceID: String?
    private let changed: (Snapshot) -> Void
    private var initialized = false
    private var refreshing = false
    private var pendingLatest = false
    private var pendingMore = false

    init(configuration: CLIConfiguration, instanceID: String? = nil, changed: @escaping (Snapshot) -> Void) {
        self.configuration = configuration; self.instanceID = instanceID; self.changed = changed
    }
    private func publish(_ edit: (inout Snapshot) -> Void) {
        var next = snapshot; edit(&next)
        guard next != snapshot else { return }
        snapshot = next; changed(next)
    }
    func refresh(more: Bool = false) async {
        if more && initialized && snapshot.cursor == nil { return }
        if refreshing {
            if more { pendingMore = true } else { pendingLatest = true }
            return
        }
        refreshing = true
        defer { refreshing = false }
        var more = more
        repeat {
            publish { $0.loadingMore = more }
            do {
                let args = ["executions", "--limit", "100"]
                    + (instanceID.map { ["--instance", $0] } ?? [])
                    + (more ? snapshot.cursor.map { ["--before", $0] } ?? [] : [])
                let client = CLIClient(configuration)
                let reply = try await client.sandbox(args, timeout: 15).reply()
                if Task.isCancelled { break }
                var fresh = (reply.executions ?? []) + (reply.pendingExecutions ?? [])
                let freshIDs = Set(fresh.map(\.id))
                for previous in snapshot.records where ["queued", "running"].contains(previous.state) && !freshIDs.contains(previous.id) {
                    guard let detail = try await client.sandbox(["execution", previous.id], timeout: 15).reply().execution,
                          detail.id == previous.id, detail.instanceID == previous.instanceID else {
                        throw CLIError(ui("未返回对应任务的执行详情：", "No execution details returned for task: ") + previous.id)
                    }
                    if Task.isCancelled { break }
                    var updated = previous
                    updated.state = detail.state; updated.automaticVerification = detail.automaticVerification
                    fresh.append(updated)
                }
                if Task.isCancelled { break }
                publish { next in
                    var records = Dictionary(next.records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                    for record in fresh { records[record.id] = record }
                    next.records = records.values.sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
                    if !initialized || more { next.cursor = reply.nextExecutionCursor }
                    next.error = nil
                }
                initialized = true
            } catch {
                if !Task.isCancelled { publish { $0.error = error.localizedDescription } }
            }
            if pendingMore {
                pendingMore = false
                if snapshot.cursor != nil { more = true; continue }
            }
            if pendingLatest { pendingLatest = false; more = false; continue }
            break
        } while !Task.isCancelled
        pendingLatest = false; pendingMore = false
        publish { $0.loadingMore = false }
    }
}
