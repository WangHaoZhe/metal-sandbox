import Foundation
import Darwin
import SandboxCore
import SandboxRuntime

func runNativeShellDisconnectTests(bin: URL, output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SandboxError("shell disconnect output must be new") }
    try SafeFiles.secureDirectory(output)
    var results: [ProcessOutcome] = []
    for parallel in [false, true] {
        let directory = output.appendingPathComponent(parallel ? "parallel" : "serial")
        let policy = parallel ? TaskPolicy(serial: []) : TaskPolicy()
        let scheduler = try ExecutionScheduler(coordinationDirectory: directory.appendingPathComponent("coordination"), taskPolicy: policy)
        let factory = try AppSandboxFactory(binDirectory: bin, directory: directory.appendingPathComponent("runtime"), scheduler: scheduler)
        let host = try factory.create(taskPolicy: policy)
        defer { try? host.close(); _ = try? factory.purge(host.id) }
        let script = #"""
        "$METAL_SANDBOX_SHELL_HELPER" 'printf "%s\n" "$$" > candidate_group; /bin/sleep 60 & printf "%s\n" "$!" > candidate_child; wait' &
        printf '%s\n' "$!" > helper_pid
        wait
        printf '%s\n' session_survived
        """#
        try host.write(WorkspaceFile(path: "session.sh", data: Data(script.utf8)))
        for number in [SIGKILL, SIGABRT] {
            let done = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var result: Result<NativeResult, Error>?
            let cancellation = CancellationToken()
            var command = NativeCommand(["/bin/bash", "./session.sh"], timeoutSeconds: 15)
            command.agentSession = true
            DispatchQueue.global().async {
                let finished = Result { try host.execute(command, cancellation: cancellation) }
                lock.lock(); result = finished; lock.unlock(); done.signal()
            }
            func readPID(_ path: String) -> Int32? {
                guard let file = try? host.read(path) else { return nil }
                return Int32(String(decoding: file.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let deadline = Date().addingTimeInterval(10)
            var helper: Int32?, group: Int32?, child: Int32?
            while helper == nil || group == nil || child == nil {
                helper = readPID("helper_pid"); group = readPID("candidate_group"); child = readPID("candidate_child")
                if Date() >= deadline {
                    cancellation.cancel()
                    _ = done.wait(timeout: .now() + 5)
                    throw SandboxError("owned shell candidate did not start")
                }
                if helper == nil || group == nil || child == nil { Thread.sleep(forTimeInterval: 0.02) }
            }
            guard let helper, let group, let child, group > 0, getpgid(group) == group, getpgid(child) == group else {
                throw SandboxError("owned shell candidate group mismatch")
            }
            defer { _ = ProcessGroup.clean(group) }
            guard kill(helper, number) == 0 else { throw SandboxError("cannot terminate owned shell helper") }
            guard done.wait(timeout: .now() + 10) == .success else {
                cancellation.cancel()
                throw SandboxError("Agent session did not finish after helper termination")
            }
            lock.lock(); let finished = result; lock.unlock()
            guard let finished else { throw SandboxError("missing Agent session result") }
            let session = try finished.get()
            results.append(session.outcome)
            guard session.outcome.exitCode == 0, String(decoding: session.stdout, as: UTF8.self).contains("session_survived") else {
                throw SandboxError("helper termination interrupted the Agent session")
            }
            guard ProcessGroup.waitForAbsence(group, seconds: 3) else { throw SandboxError("helper termination left candidate processes") }
            guard scheduler.recoveryReason == nil else { throw SandboxError("cleaned shell termination quarantined the node") }
            let next = try host.execute(NativeCommand(["/bin/echo", "next_command"], timeoutSeconds: 5))
            guard next.outcome.exitCode == 0, String(decoding: next.stdout, as: UTF8.self).contains("next_command") else {
                throw SandboxError("cleaned shell termination retained its execution permit")
            }
            for path in ["helper_pid", "candidate_group", "candidate_child"] {
                try host.write(WorkspaceFile(path: path, data: Data()))
            }
            print("PASS \(parallel ? "parallel" : "serial") helper signal \(number): candidate group cleaned, Agent preserved, next command admitted")
        }
    }
    try SafeFiles.write(results, to: output.appendingPathComponent("session_outcomes.json"))
}
