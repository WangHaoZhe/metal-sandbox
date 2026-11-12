import Foundation
import Darwin
import SandboxCore
import SandboxRuntime
import SandboxManagement

func runNativeRecoveryTests(bin: URL, output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SandboxError("recovery output must be new") }
    try SafeFiles.secureDirectory(output)
    let state = output.appendingPathComponent("state")
    let manager = try NativeManager(directory: state, binDirectory: bin, coordinationDirectory: output.appendingPathComponent("coordination"))
    defer { manager.shutdown() }
    let token = try NativeControlClient.operatorToken(stateDirectory: state)
    func call(_ input: NativeControlRequest) -> NativeControlReply {
        var input = input; input.operatorToken = token; return manager.handle(input)
    }
    func checked(_ input: NativeControlRequest) throws -> NativeControlReply {
        let reply = call(input)
        guard reply.ok else { throw SandboxError(reply.error ?? "recovery test request failed") }
        return reply
    }
    func wait(_ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(15)
        while try !condition() {
            guard Date() < deadline else { throw SandboxError("recovery condition timed out") }
            usleep(20_000)
        }
    }
    func execution(_ id: String) throws -> NativeExecutionRecord {
        var request = NativeControlRequest("execution"); request.executionID = id
        return try unwrap(checked(request).execution)
    }
    func submit(_ id: String, _ script: String, session: Bool = false, timeout: Double = 30) throws -> String {
        var request = NativeControlRequest("exec"); request.instanceID = id
        var command = NativeCommand(["/bin/sh", "-c", script], timeoutSeconds: timeout)
        command.agentSession = session; request.command = command
        return try unwrap(checked(request).execution).id
    }
    func read(_ id: String, _ path: String) throws -> String {
        var request = NativeControlRequest("read"); request.instanceID = id; request.path = path
        return String(decoding: try unwrap(checked(request).file).data, as: UTF8.self)
    }
    var create = NativeControlRequest("create"); create.count = 2
    let instances = try unwrap(checked(create).instances)
    let controller = instances[0], victim = instances[1]
    let sessionID = try submit(controller.id, "go=0; trap 'go=1' USR1; echo $$ > session_pid; while [ \"$go\" = 0 ]; do sleep 0.05; done; \"$METAL_SANDBOX_SHELL_HELPER\" \"env /bin/sh -c 'printf child-resumed > child_done'\"; while [ ! -e release ]; do sleep 0.05; done; printf session-kept > session_result", session: true, timeout: 90)
    try wait { (try? read(controller.id, "session_pid")) != nil }
    let originalPID = try read(controller.id, "session_pid")
    let commandID = try submit(victim.id, "echo $$ > child_pid; exec /bin/sleep 60", timeout: 70)
    try wait { (try? read(victim.id, "child_pid")) != nil }
    let child = try unwrap(Int32(read(victim.id, "child_pid").trimmingCharacters(in: .whitespacesAndNewlines)))
    guard getpgid(child) == child else { throw SandboxError("owned child identity changed") }
    var needsCleanup = true
    defer { if needsCleanup && getpgid(child) == child { _ = kill(-child, SIGKILL) } }
    guard kill(try unwrap(victim.physical).pid, SIGKILL) == 0 else { throw SandboxError("cannot terminate owned test Host") }
    try wait { try manager.status.recoveryReason != nil && execution(commandID).isTerminal }
    _ = kill(-child, SIGKILL)
    guard ProcessGroup.waitForAbsence(child, seconds: 5) else { throw SandboxError("test child group remains") }
    needsCleanup = false
    var recover = NativeControlRequest("recover"); recover.confirmed = true
    recover.note = "Owned CPU-only test Host was terminated; its exact child group was reaped and checked."
    guard !call(recover).ok else { throw SandboxError("recovered with a disconnected Host") }
    var stop = NativeControlRequest("stop"); stop.instanceID = victim.id
    _ = call(stop)
    let controllerPID = try unwrap(Int32(originalPID.trimmingCharacters(in: .whitespacesAndNewlines)))
    guard kill(controllerPID, SIGUSR1) == 0 else { throw SandboxError("cannot notify owned Agent session") }
    let queued = try submit(controller.id, "env /bin/sh -c 'printf resumed > resumed'", timeout: 0.5)
    let cancelled = try submit(controller.id, "env /bin/sh -c 'printf wrong > cancelled'", timeout: 0.5)
    try wait { manager.status.executionCounts.serialWaiting >= 3 }
    usleep(700_000)
    guard try execution(queued).state == "queued" else { throw SandboxError("quarantined command did not wait") }
    var cancel = NativeControlRequest("cancel"); cancel.executionID = cancelled
    _ = try checked(cancel)
    try wait { try execution(cancelled).isTerminal }
    guard try execution(cancelled).state == "cancelled" else { throw SandboxError("waiting command cancellation failed") }
    _ = try checked(recover)
    try wait { try execution(queued).isTerminal }
    try wait { (try? read(controller.id, "child_done")) == "child-resumed" }
    guard try execution(queued).state == "succeeded",
          try read(controller.id, "resumed") == "resumed",
          try read(controller.id, "session_pid") == originalPID else { throw SandboxError("session did not continue after recovery") }
    let finish = try submit(controller.id, "touch release")
    try wait { try execution(finish).isTerminal && execution(sessionID).isTerminal }
    guard try execution(sessionID).state == "succeeded", manager.status.recoveryReason == nil else {
        throw SandboxError("live Agent lease was damaged by recovery")
    }
    stop.instanceID = controller.id; _ = try checked(stop)
    var restart = NativeControlRequest("start"); restart.instanceID = victim.id
    _ = try checked(restart)
    stop.instanceID = victim.id; _ = try checked(stop)
    for item in instances {
        var remove = NativeControlRequest("delete"); remove.instanceID = item.id; remove.confirmed = true
        _ = try checked(remove)
    }
    try SafeFiles.write(["result": "passed", "sessionPID": originalPID.trimmingCharacters(in: .whitespacesAndNewlines),
                         "checks": "real Host loss; preserved live Agent; shell helper continued; queued deadline excluded; cancellation; no duplicated execution; live lease retained"],
                        to: output.appendingPathComponent("report.json"))
    print("PASS native quarantine/recovery without restarting the Agent session")
}
