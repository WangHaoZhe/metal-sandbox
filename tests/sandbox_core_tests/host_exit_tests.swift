import Foundation
import Darwin
import SandboxCore
import SandboxRuntime

func runHostExitDiagnostics(bin: URL, output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SandboxError("use a fresh test output directory") }
    try SafeFiles.secureDirectory(output)
    let scheduler = try ExecutionScheduler(coordinationDirectory: output.appendingPathComponent("coordination"))
    let factory = try AppSandboxFactory(binDirectory: bin, directory: output.appendingPathComponent("runtime"), scheduler: scheduler)
    let normal = try factory.create()
    try normal.close()
    guard scheduler.recoveryReason == nil else { throw SandboxError("normal shutdown incorrectly quarantined") }
    _ = try factory.purge(normal.id)
    let host = try factory.create()
    // Exact live PID owned by this test. No workload, descendants or GPU use.
    guard kill(host.info.pid, SIGTERM) == 0 else { throw SandboxError("cannot terminate owned idle fixture") }
    let end = Date().addingTimeInterval(5)
    let log = output.appendingPathComponent("runtime/instances/\(host.id)/host_exit.json")
    while host.connectionError == nil || !FileManager.default.fileExists(atPath: log.path) {
        guard Date() < end else { throw SandboxError("Host exit was not diagnosed") }
        Thread.sleep(forTimeInterval: 0.02)
    }
    let exit = try SafeFiles.read([String: String].self, from: log)
    guard exit["reason"] == "signal", exit["status"] == String(SIGTERM) else { throw SandboxError("missing real exit signal") }
    do { _ = try host.trajectory(session: nil, after: nil); throw SandboxError("dead Host was accepted") }
    catch {
        guard String(describing: error).contains("signal 15"), !String(describing: error).contains("private IPC write failed") else { throw error }
    }
    guard scheduler.recoveryReason == nil else { throw SandboxError("idle Host exit quarantined the node") }
    var rejected = false
    do { _ = try host.execute(NativeCommand(["/bin/echo", "must-not-run"])) } catch { rejected = true }
    guard rejected, scheduler.recoveryReason == nil else { throw SandboxError("dead idle Host execution handling") }
    try host.close()
    guard host.connectionError != nil else { throw SandboxError("Host exit evidence was lost") }
    _ = try factory.purge(host.id)
    let busy = try factory.create()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { done.signal() }
        do {
            _ = try busy.execute(NativeCommand(["/bin/sh", "-c", "echo $$ > owned_child; exec /bin/sleep 30"], timeoutSeconds: 40))
            fail("running Host exit was accepted")
        } catch {}
    }
    let ready = Date().addingTimeInterval(5)
    var child: Int32?
    while child == nil {
        if let data = try? busy.read("owned_child").data {
            child = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard Date() < ready else { throw SandboxError("owned sleep did not start") }
        if child == nil { Thread.sleep(forTimeInterval: 0.02) }
    }
    guard let child, child > 0, getpgid(child) == child else { throw SandboxError("owned child group mismatch") }
    var childNeedsCleanup = true
    defer { if childNeedsCleanup, getpgid(child) == child { _ = kill(-child, SIGKILL) } }
    guard kill(busy.info.pid, SIGTERM) == 0 else { throw SandboxError("cannot stop owned busy Host") }
    guard done.wait(timeout: .now() + 5) == .success, scheduler.recoveryReason != nil else {
        throw SandboxError("running Host loss did not retain quarantine")
    }
    _ = kill(-child, SIGTERM)
    let cleaned = Date().addingTimeInterval(5)
    while kill(-child, 0) == 0, Date() < cleaned { Thread.sleep(forTimeInterval: 0.02) }
    guard kill(-child, 0) < 0, errno == ESRCH else { throw SandboxError("owned CPU-only group remains") }
    childNeedsCleanup = false
    rejected = false
    do { try busy.close() } catch { rejected = true }
    guard rejected, scheduler.recoveryReason != nil else { throw SandboxError("busy Host failure evidence was lost") }
    _ = try factory.purge(busy.id)
    // Keep this test's separate quarantine journal; never recover the real node.
    print("PASS native Host lifecycle: idle failure remains local; running Host loss retains quarantine; owned CPU-only children cleaned")
}
