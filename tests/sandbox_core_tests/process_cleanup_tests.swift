import Foundation
import Darwin
import SandboxCore
import SandboxRuntime

func runNativeProcessCleanupTests(bin: URL, output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SandboxError("cleanup output must be new") }
    try SafeFiles.secureDirectory(output)
    let scheduler = try ExecutionScheduler(coordinationDirectory: output.appendingPathComponent("coordination"))
    let factory = try AppSandboxFactory(binDirectory: bin, directory: output.appendingPathComponent("runtime"), scheduler: scheduler)
    let host = try factory.create()
    defer { try? host.close(); _ = try? factory.purge(host.id) }
    let source = #"""
    #include <errno.h>
    #include <signal.h>
    #include <stdio.h>
    #include <sys/wait.h>
    #include <unistd.h>

    int main(void) {
        for (int round = 0; round < 40; ++round) {
            pid_t child = fork();
            if (child < 0) return 2;
            if (child == 0) {
                if (setpgid(0, 0) != 0) _exit(3);
                pid_t descendant = fork();
                if (descendant < 0) _exit(4);
                if (descendant == 0) { usleep((round % 5 + 1) * 1000); _exit(0); }
                _exit(0);
            }
            setpgid(child, child);
            int status = 0;
            if (waitpid(child, &status, 0) != child || status != 0) return 5;
            int unknown = 0, code = 0;
            for (int probe = 0; probe < 200; ++probe) {
                int result = kill(-child, 0);
                code = result < 0 ? errno : 0;
                if (code == ESRCH) break;
                if (code != 0) unknown = code;
                usleep(1000);
            }
            printf("{\"group\":%d,\"unknown_errno\":%d,\"final_errno\":%d}\n", child, unknown, code);
        }
        return 0;
    }
    """#
    try host.write(WorkspaceFile(path: "group_probe.c", data: Data(source.utf8)))
    let compilation = try host.execute(NativeCommand(["/bin/bash", "-c", "\"$CC\" -isysroot \"$SDKROOT\" group_probe.c -o group_probe"], timeoutSeconds: 30))
    guard compilation.outcome.exitCode == 0 else { throw SandboxError(String(decoding: compilation.stderr, as: UTF8.self)) }
    let probe = try host.execute(NativeCommand(["./group_probe"], timeoutSeconds: 30))
    try SafeFiles.write(probe, to: output.appendingPathComponent("sandbox_probe.json"))
    guard probe.outcome.exitCode == 0 else { throw SandboxError("sandbox process probe failed") }
    struct Row: Decodable { let group: Int32; let unknown_errno: Int32; let final_errno: Int32 }
    let rows = try String(decoding: probe.stdout, as: UTF8.self).split(separator: "\n").map {
        try JSON.decoder().decode(Row.self, from: Data($0.utf8))
    }
    guard rows.count == 40, rows.allSatisfy({ ProcessGroup.waitForAbsence($0.group, seconds: 1) }) else {
        throw SandboxError("probe left a live process group")
    }
    print("Sandbox probes with unknown errno: \(rows.filter { $0.unknown_errno != 0 }.count)/40")
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    try host.write(WorkspaceFile(path: "group_support.swift", data: Data(contentsOf: project.appendingPathComponent("sources/sandbox_core/process_group.swift"))))
    let direct = #"""
    import Foundation
    import Darwin
    for index in 0..<80 {
        var child: pid_t = 0
        var attributes: posix_spawnattr_t?
        if posix_spawnattr_init(&attributes) != 0 { exit(2) }
        defer { posix_spawnattr_destroy(&attributes) }
        if posix_spawnattr_setpgroup(&attributes, 0) != 0 { exit(3) }
        if posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) != 0 { exit(4) }
        var argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", "/bin/sleep 0.00\(index % 5 + 1) & exit 0"].map {
            (value: String) in value.withCString { strdup($0) }
        } + [nil]
        var environment = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        let spawned = argv.withUnsafeMutableBufferPointer { args in
            environment.withUnsafeMutableBufferPointer { env in
                posix_spawn(&child, "/bin/sh", nil, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        if spawned != 0 { exit(5) }
        var status: Int32 = 0
        if waitpid(child, &status, 0) != child || status != 0 { exit(5) }
        let result = ProcessGroup.clean(child)
        let data = try JSONEncoder().encode(result.diagnostics)
        FileHandle.standardOutput.write(data + Data([10]))
        if !result.gone { exit(6) }
    }
    """#
    try host.write(WorkspaceFile(path: "main.swift", data: Data(direct.utf8)))
    let swift = try host.execute(NativeCommand(["/bin/bash", "-c", "swiftc -sdk \"$SDKROOT\" group_support.swift main.swift -o swift_group_probe"], timeoutSeconds: 60))
    guard swift.outcome.exitCode == 0 else { throw SandboxError(String(decoding: swift.stderr, as: UTF8.self)) }
    let cleaned = try host.execute(NativeCommand(["./swift_group_probe"], timeoutSeconds: 90))
    try SafeFiles.write(cleaned, to: output.appendingPathComponent("direct_cleanup.json"))
    guard cleaned.outcome.exitCode == 0 else { throw SandboxError("cleanup implementation did not confirm real child groups") }
    let diagnostics = try String(decoding: cleaned.stdout, as: UTF8.self).split(separator: "\n").map {
        try JSON.decoder().decode(ProcessCleanupDiagnostics.self, from: Data($0.utf8))
    }
    guard diagnostics.count == 80, diagnostics.allSatisfy({ $0.finalProbeError == ESRCH }) else {
        throw SandboxError("missing final group absence confirmation")
    }
    print("Cleanup implementation handled probe errors in \(diagnostics.filter { !$0.probeErrors.isEmpty }.count)/80 cases")
    var results: [ProcessOutcome] = []
    for _ in 0..<160 {
        do {
            let result = try host.execute(NativeCommand(["/bin/sh", "-c", "sleep 1 & exit 0"], timeoutSeconds: 5))
            results.append(result.outcome)
            guard result.outcome.exitCode == 0, result.outcome.processGroupGone else { throw SandboxError("background cleanup failed") }
        } catch let error as UncertainExecution {
            try SafeFiles.write(error.result, to: output.appendingPathComponent("uncertain.json"))
            print("Manager observation: \(ProcessGroup.observe(error.result.outcome.processID))")
            throw error
        }
    }
    try SafeFiles.write(results, to: output.appendingPathComponent("completed.json"))
    guard scheduler.recoveryReason == nil else { throw SandboxError("clean processes quarantined the node") }
    print("PASS 160 native background process cleanup checks")
}
