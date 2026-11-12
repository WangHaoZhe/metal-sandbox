import Foundation
import CryptoKit
import Darwin
import SandboxCore
import SandboxRuntime
import EvaluationCore

// No fake runtime is linked into the production executables. These tests verify
// control-plane logic only, not native/App Sandbox/Metal acceptance.
private func syntheticResult(_ lease: String, reason: String = "exited", exitCode: Int = 0, stdout: String = "42\n", processGroupGone: Bool = true) throws -> NativeResult {
    let outcome = try JSON.decoder().decode(ProcessOutcome.self, from: JSONSerialization.data(withJSONObject: [
        "processID": 123, "reason": reason, "exitCode": exitCode, "elapsedSeconds": 0.01,
        "cleanupSeconds": 0, "processGroupGone": processGroupGone,
    ]))
    return NativeResult(leaseID: lease, outcome: outcome, stdout: Data(stdout.utf8), stderr: Data())
}

private final class MemorySandbox: SandboxSession {
    let id: String
    var files: [String: WorkspaceFile] = [:]
    var commands: [NativeCommand] = []
    var closed = false
    var failClose = false
    var executionStarted: DispatchSemaphore?
    var executionRelease: DispatchSemaphore?
    init(_ id: String) { self.id = id }
    func read(_ path: String) throws -> WorkspaceFile {
        guard let file = files[path] else { throw SandboxError("missing test file") }; return file
    }
    func write(_ file: WorkspaceFile) throws { files[file.path] = file }
    func listDirectory(_ path: String, after: String?) throws -> WorkspaceDirectory {
        WorkspaceDirectory(path: path, entries: [], nextAfter: nil)
    }
    func export() throws -> [WorkspaceFile] { Array(files.values) }
    func execute(_ command: NativeCommand) throws -> NativeResult {
        executionStarted?.signal()
        if let executionRelease, executionRelease.wait(timeout: .now() + 5) != .success {
            throw SandboxError("test execution was not released")
        }
        commands.append(command)
        let badSource = files["fixture_main.c"].map { String(decoding: $0.data, as: UTF8.self).contains("broken") } ?? false
        return try syntheticResult(UUID().uuidString, exitCode: badSource ? 1 : 0, stdout: badSource ? "compile error\n" : "42\n")
    }
    func close() throws { closed = true; if failClose { throw SandboxError("test cleanup failure") } }
}

final class RuntimeTests {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-runtime-test-\(UUID().uuidString.lowercased())")
        try SafeFiles.secureDirectory(root)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func workspace() throws -> ConfinedWorkspace {
        let path = root.appendingPathComponent("work")
        try SafeFiles.secureDirectory(path)
        return try ConfinedWorkspace(directory: path)
    }
    func cancellationAtExit() throws {
        let token = CancellationToken()
        let outcome = try ProcessRunner.run(argv: ["/bin/sh", "-c", "exit 0"], workingDirectory: root,
            home: root, temporary: root, stdout: root.appendingPathComponent("out"), stderr: root.appendingPathComponent("err"),
            timeout: 5, maxLogBytes: 1024, jobID: "exit-cancellation-test", cancellation: token) { pid in
                var info = siginfo_t()
                guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 else { throw SandboxError("waitid test fixture failed") }
                token.cancel() // The child has exited, but ProcessRunner has not reaped it yet.
            }
        expectEqual(outcome.reason, .cancelled)
        expectEqual(outcome.exitCode, 0)
        expectTrue(outcome.processGroupGone)
        expectFalse(outcome.requiresInspection)
    }
    func paths() throws {
        expectTrue(HostRequest.Operation.classifyCommand.allowedDuringExecution)
        for operation in [HostRequest.Operation.read, .trajectory, .executionResult, .exec] { expectTrue(operation.allowedDuringExecution) }
        for operation in [HostRequest.Operation.write, .export, .upload, .purge] { expectFalse(operation.allowedDuringExecution) }
        for path in ["", "/absolute", "../escape", "a/../b", "a//b", "a/./b", "a/", "nul\0x"] {
            expectThrows(try ConfinedWorkspace.components(path))
        }
        expectEqual(try ConfinedWorkspace.components("src/fixture_main.c"), ["src", "fixture_main.c"])
        expectThrows(try NativeCommand(["clang"]).validate())
        expectThrows(try NativeCommand([]).validate())
        expectThrows(try NativeCommand(["./../outside"]).validate())
        expectThrows(try NativeCommand(["/bin/sh", "x\0y"]).validate())
        expectThrows(try NativeCommand(["/bin/sh"], timeoutSeconds: .nan).validate())
        expectThrows(try NativeCommand(["/bin/sh"], maxLogBytes: 1023).validate())
        expectThrows(try NativeCommand(["/bin/sh"], maxLogBytes: 4 * 1024 * 1024 + 1).validate())
        expectThrows(try NativeCommand(["/bin/sh"] + Array(repeating: "a", count: 256)).validate())
        expectThrows(try NativeCommand(["/bin/sh", String(repeating: "a", count: 32769)]).validate())
        expectThrows(try NativeCommand(["/bin/sh"] + Array(repeating: String(repeating: "a", count: 32768), count: 5)).validate())
        expectThrows(try NativeCommand(["/bin/sh"], cwd: "../outside").validate())
        expectNoThrow(try NativeCommand(["/bin/sh", "-c", "echo hi"]).validate())
    }
    func fileRoundtrip() throws {
        let w = try workspace()
        let file = WorkspaceFile(path: "src/a.c", data: Data("first".utf8), executable: true)
        try w.write(file); expectEqual(try w.read(file.path), file)
        try w.write(WorkspaceFile(path: file.path, data: Data("second".utf8)))
        expectEqual(try w.read(file.path).data, Data("second".utf8))
        expectFalse(try w.read(file.path).executable)
        expectEqual(try w.export().count, 1)
        let large = WorkspaceFile(path: "huge", data: Data(repeating: 37, count: 5 * 1024 * 1024))
        try w.write(large); expectEqual(try w.read("huge"), large)
        let alias = WorkspaceFile(path: "src/lib.dylib", data: Data(), linkTarget: "lib.1.dylib")
        try w.write(alias)
        expectEqual(try w.export().first(where: { $0.path == alias.path }), alias)
        expectThrows(try w.read(alias.path))
        for target in ["../outside", "/etc/passwd", "dir/file", ".", "..", ""] {
            expectThrows(try w.write(WorkspaceFile(path: "invalid", data: Data(), linkTarget: target)))
        }
        expectThrows(try w.write(WorkspaceFile(path: "invalid", data: Data([1]), linkTarget: "sibling")))
        expectThrows(try w.write(WorkspaceFile(path: "invalid", data: Data(), executable: true, linkTarget: "sibling")))
    }
    func streamingArchive() throws {
        let w = try workspace(), archive = root.appendingPathComponent("snapshot.zip")
        let source = root.appendingPathComponent("source")
        let chunk = Data(repeating: 53, count: WorkspaceArchive.chunkSize)
        try WorkspaceArchive.atomic(source) { output in for _ in 0..<160 { try output.write(contentsOf: chunk) } }
        try WorkspaceArchive.fromFile(source, path: "nested/large", executable: true, to: archive)
        try w.importArchive(from: archive)
        try w.write(WorkspaceFile(path: "nested/alias", data: Data(), linkTarget: "large"))
        try w.exportArchive(to: archive)
        let stats = try WorkspaceArchive.read(archive)
        expectEqual(stats.files, 2); expectEqual(stats.bytes, 40 * 1024 * 1024)
        let destination = root.appendingPathComponent("clone")
        try SafeFiles.secureDirectory(destination)
        let clone = try ConfinedWorkspace(directory: destination)
        try clone.importArchive(from: archive)
        var observed: Int64 = 0
        try WorkspaceArchive.read(archive) { entry, extract in
            if entry.file.path == "nested/large" { expectTrue(entry.file.executable) }
            try extract { data in expectEqual(data, Data(repeating: 53, count: data.count)); observed += Int64(data.count) }
        }
        expectEqual(observed, stats.bytes)
        let corrupt = root.appendingPathComponent("corrupt.zip")
        try WorkspaceArchive.copy(archive, to: corrupt)
        let handle = try FileHandle(forWritingTo: corrupt)
        try handle.seek(toOffset: 2000); try handle.write(contentsOf: Data([255])); try handle.close()
        try clone.write(WorkspaceFile(path: "nested/large", data: Data("keep".utf8)))
        expectThrows(try clone.importArchive(from: corrupt))
        expectEqual(try clone.read("nested/large").data, Data("keep".utf8))
        let truncated = root.appendingPathComponent("truncated.zip")
        try WorkspaceArchive.copy(archive, to: truncated)
        let cut = try FileHandle(forWritingTo: truncated); try cut.truncate(atOffset: 1000); try cut.close()
        expectThrows(try clone.importArchive(from: truncated))
        expectEqual(try clone.read("nested/large").data, Data("keep".utf8))
        let before = try Data(contentsOf: archive).count
        expectThrows(try WorkspaceArchive.write(archive) { writer in
            try writer.append(WorkspaceFile(path: "a", data: Data()))
            try writer.append(WorkspaceFile(path: "A/file", data: Data()))
        })
        expectEqual(try Data(contentsOf: archive).count, before)
        let json = root.appendingPathComponent("not_archive.json")
        try SafeFiles.write([WorkspaceFile(path: "unexpected", data: Data("not a ZIP".utf8))], to: json)
        expectFalse(try WorkspaceArchive.isArchive(json))
        expectThrows(try clone.importArchive(from: json))
        expectThrows(try clone.read("unexpected"))
    }
    func streamingFrames() throws {
        let archive = root.appendingPathComponent("source.zip"), dest = root.appendingPathComponent("destination.zip")
        // Incompressible payload forces more than one transport chunk.
        var noise = Data(count: WorkspaceArchive.chunkSize * 2 + 127), random: UInt32 = 0x12345678
        for i in noise.indices {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5
            noise[i] = UInt8(truncatingIfNeeded: random)
        }
        try WorkspaceArchive.write(archive) { writer in
            for i in 0..<5 { try writer.append(WorkspaceFile(path: "file-\(i)", data: Data(repeating: UInt8(i), count: 5 * 1024 * 1024))) }
            try writer.append(WorkspaceFile(path: "noise", data: noise))
        }
        let expectedBytes = Int64(25 * 1024 * 1024 + noise.count)
        let corrupt = root.appendingPathComponent("bad_crc.zip"), truncated = root.appendingPathComponent("truncated.zip")
        let bytes = try Data(contentsOf: archive)
        var badCRC = bytes
        let header = badCRC.range(of: Data([0x50, 0x4b, 0x01, 0x02]), options: .backwards)!.lowerBound
        badCRC[header + 16] ^= 1 // Alter only the last entry's declared CRC.
        try badCRC.write(to: corrupt); try bytes.dropLast(22).write(to: truncated)
        let empty = root.appendingPathComponent("empty.zip"), missing = root.appendingPathComponent("missing.zip")
        try WorkspaceArchive.write(empty) { _ in }
        let pipe = Pipe()
        let tx = try FramedChannel(input: pipe.fileHandleForReading.fileDescriptor, output: pipe.fileHandleForWriting.fileDescriptor)
        let rx = tx
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                for source in [archive, archive, archive, corrupt, truncated, missing, archive, empty] {
                    _ = try tx.sendFile(source); try tx.send(["marker": "aligned"])
                }
            } catch { fail("stream send: \(error)") }
        }
        var summary: WorkspaceArchive.Summary?, hash = SHA256(), validationCalls = 0, chunks = 0
        expectNil(try rx.receiveFile(to: dest, validate: {
            validationCalls += 1; summary = try WorkspaceArchive.read($0)
        }, didWrite: { hash.update(data: $0); chunks += 1 }))
        expectEqual(validationCalls, 1); expectTrue(chunks > 1)
        expectEqual(summary?.files, 6); expectEqual(summary?.bytes, expectedBytes)
        let previousDigest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        expectEqual(previousDigest, try WorkspaceArchive.digest(dest))
        expectEqual(previousDigest, try WorkspaceArchive.digest(archive))
        expectEqual(try rx.receive([String:String].self)?["marker"], "aligned")
        // Destination creation fails: consume all chunks and keep IPC aligned.
        var failedChunks = 0
        expectTrue(try rx.receiveFile(to: root.appendingPathComponent("absent/file"), didWrite: { _ in failedChunks += 1 }) != nil)
        expectEqual(failedChunks, 0)
        expectEqual(try rx.receive([String:String].self)?["marker"], "aligned")
        expectTrue(try rx.receiveFile(to: dest, validate: { _ in throw SandboxError("reject integrity") }) != nil)
        expectEqual(try WorkspaceArchive.digest(dest), previousDigest)
        expectEqual(try rx.receive([String:String].self)?["marker"], "aligned")
        // Real CRC damage, truncation and sender errors must also retain the
        // old archive and leave the channel usable for the next transfer.
        for _ in 0..<3 {
            expectTrue(try rx.receiveFile(to: dest, validate: { _ = try WorkspaceArchive.read($0) }) != nil)
            expectEqual(try WorkspaceArchive.digest(dest), previousDigest)
            expectEqual(try rx.receive([String:String].self)?["marker"], "aligned")
        }
        validationCalls = 0
        expectNil(try rx.receiveFile(to: dest, validate: { validationCalls += 1; summary = try WorkspaceArchive.read($0) }))
        expectEqual(validationCalls, 1); expectEqual(summary?.bytes, expectedBytes)
        expectEqual(try rx.receive([String:String].self)?["marker"], "aligned")
        expectNil(try rx.receiveFile(to: dest, validate: { summary = try WorkspaceArchive.read($0) }))
        expectEqual(summary?.files, 0); expectEqual(summary?.bytes, 0)
        expectEqual(try rx.receive([String:String].self)?["marker"], "aligned")
        expectEqual(done.wait(timeout: .now() + 30), .success)
    }
    func links() throws {
        let w = try workspace(), path = root.appendingPathComponent("work")
        let outside = root.appendingPathComponent("secret")
        try SafeFiles.writeData(Data("untouched".utf8), to: outside)
        try FileManager.default.createSymbolicLink(at: path.appendingPathComponent("link"), withDestinationURL: outside)
        expectThrows(try w.read("link")); expectThrows(try w.export())
        try w.write(WorkspaceFile(path: "link", data: Data("replacement".utf8)))
        expectEqual(try SafeFiles.readRegular(outside, limit: 100), Data("untouched".utf8))
        try FileManager.default.createSymbolicLink(at: path.appendingPathComponent("parent"), withDestinationURL: root)
        expectThrows(try w.read("parent/secret"))
        expectThrows(try w.write(WorkspaceFile(path: "parent/secret", data: Data())))
        expectEqual(link(outside.path, path.appendingPathComponent("hardlink").path), 0)
        expectThrows(try w.read("hardlink"))
        expectEqual(mkfifo(path.appendingPathComponent("fifo").path, 0o600), 0)
        expectThrows(try w.read("fifo"))
    }
    func directoryListing() throws {
        let w = try workspace(), path = root.appendingPathComponent("work")
        for name in [".hidden", "中文 file", "line\nbreak"] {
            try w.write(WorkspaceFile(path: name, data: Data("hello".utf8)))
        }
        try SafeFiles.secureDirectory(path.appendingPathComponent("empty"))
        try w.write(WorkspaceFile(path: "nested/file", data: Data()))
        let big = path.appendingPathComponent("large")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(5 * 1024 * 1024 + 10)); try handle.close()
        try FileManager.default.createSymbolicLink(at: path.appendingPathComponent("link"), withDestinationURL: root)
        expectEqual(mkfifo(path.appendingPathComponent("fifo").path, 0o600), 0)
        expectEqual(link(big.path, path.appendingPathComponent("hardlink").path), 0)
        let page = try w.listDirectory()
        expectEqual(page.entries.map(\.name), [".hidden", "中文 file", "line\nbreak", "empty", "nested", "large", "link", "fifo", "hardlink"].sorted())
        expectNil(page.nextAfter)
        expectEqual(page.entries.first { $0.name == "large" }?.size, Int64(5 * 1024 * 1024 + 10))
        expectEqual(page.entries.first { $0.name == "link" }?.kind, .symlink)
        expectEqual(page.entries.first { $0.name == "fifo" }?.kind, .other)
        expectEqual(try w.listDirectory("empty").entries.count, 0)
        expectEqual(try w.listDirectory("nested").entries.map(\.path), ["nested/file"])
        expectEqual(try w.listDirectory().entries, page.entries)
        for invalid in ["/", "..", "a/../b", "link", "link/work", "large"] { expectThrows(try w.listDirectory(invalid)) }
        for cursor in ["", "..", "a/b", "x\0y"] { expectThrows(try w.listDirectory(after: cursor)) }
        for i in 0..<520 { try w.write(WorkspaceFile(path: "pages/" + String(format: "%04d", i), data: Data())) }
        var cursor: String?, names: [String] = [], counts: [Int] = []
        repeat {
            let page = try w.listDirectory("pages", after: cursor)
            names += page.entries.map(\.name); counts.append(page.entries.count); cursor = page.nextAfter
        } while cursor != nil
        expectEqual(counts, [256, 256, 8])
        expectEqual(names, (0..<520).map { String(format: "%04d", $0) })
        expectEqual(try w.listDirectory("pages", after: "9999").entries.count, 0)
        try FileManager.default.moveItem(at: path, to: root.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root)
        expectEqual(try w.listDirectory("nested").entries.map(\.name), ["file"])
    }
    func containerShell() throws {
        let containers = root.appendingPathComponent("containers")
        try SafeFiles.secureDirectory(containers)
        let id = "local.metal-sandbox.instance-" + UUID().uuidString.lowercased()
        let base = containers.appendingPathComponent(id)
        let pref = base.appendingPathComponent("Data/Library/Preferences")
        try SafeFiles.secureDirectory(pref)
        let metadata = base.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        try SafeFiles.writeData(Data("metadata".utf8), to: metadata)
        try SafeFiles.writeData(Data("Finder layout metadata".utf8), to: base.appendingPathComponent(".DS_Store"))
        for name in ["com.apple.security.plist", "com.apple.security_common.plist"] {
            try FileManager.default.createSymbolicLink(atPath: pref.appendingPathComponent(name).path, withDestinationPath: "../../../../../Preferences/" + name)
        }
        let canary = root.appendingPathComponent("real_desktop")
        try SafeFiles.secureDirectory(canary)
        try SafeFiles.writeData(Data("keep".utf8), to: canary.appendingPathComponent("keep.txt"))
        let desktop = base.appendingPathComponent("Data/Desktop")
        try FileManager.default.createSymbolicLink(at: desktop, withDestinationURL: canary)
        expectThrows(try ContainerShell.remove(id, root: containers))
        expectTrue(FileManager.default.fileExists(atPath: metadata.path))
        let data = try ConfinedWorkspace(directory: base.appendingPathComponent("Data"))
        try data.removeAll(preservingLinks: [
            "Library/Preferences/com.apple.security.plist": "../../../../../Preferences/com.apple.security.plist",
            "Library/Preferences/com.apple.security_common.plist": "../../../../../Preferences/com.apple.security_common.plist",
        ])
        try ContainerShell.remove(id, root: containers)
        expectFalse(FileManager.default.fileExists(atPath: base.path))
        expectEqual(try SafeFiles.readRegular(canary.appendingPathComponent("keep.txt"), limit: 100), Data("keep".utf8))
        expectNoThrow(try ContainerShell.remove(id, root: containers))
        try FileManager.default.createSymbolicLink(at: base, withDestinationURL: canary)
        expectThrows(try ContainerShell.remove(id, root: containers))
        expectTrue(FileManager.default.fileExists(atPath: canary.appendingPathComponent("keep.txt").path))
        expectThrows(try ContainerShell.remove("../real_desktop", root: containers))
    }
    func containerLocations() throws {
        let containers = root.appendingPathComponent("containers")
        try SafeFiles.secureDirectory(containers)
        let ids = (0..<4).map { _ in "local.metal-sandbox.instance-" + UUID().uuidString.lowercased() }
        let directories = ids.map { containers.appendingPathComponent($0) }
        try SafeFiles.secureDirectory(directories[0])
        let canary = directories[0].appendingPathComponent("canary")
        try SafeFiles.writeData(Data("keep".utf8), to: canary)
        try FileManager.default.createSymbolicLink(at: directories[1], withDestinationURL: directories[0])
        try SafeFiles.writeData(Data("file".utf8), to: directories[2])
        let result = try ContainerShell.locations([ids[0], ids[3], ids[0]], root: containers)
        expectEqual(result.urls.map(\.path), [directories[0].path])
        expectEqual(result.missing, [ids[3]])
        for inputs in [[], [ids[1]], [ids[2]], ["../outside"], ["file:///tmp"], [ids[0], "../outside"]] {
            expectThrows(try ContainerShell.locations(inputs, root: containers))
        }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: containers)
        expectThrows(try ContainerShell.locations([ids[0]], root: alias))
        expectEqual(try SafeFiles.readRegular(canary, limit: 100), Data("keep".utf8))
        expectEqual(try SafeFiles.readRegular(directories[2], limit: 100), Data("file".utf8))
        expectFalse(FileManager.default.fileExists(atPath: directories[3].path))
    }
    func instanceNames() throws {
        expectEqual(try NativeInstanceRecord.replicaNames(nil, count: 2), [nil, nil])
        expectEqual(try NativeInstanceRecord.replicaNames("   ", count: 2), [nil, nil])
        expectEqual(try NativeInstanceRecord.replicaNames(" 毒蘑菇 ", count: 1), ["毒蘑菇"])
        expectEqual(try NativeInstanceRecord.replicaNames("毒蘑菇", count: 3), ["毒蘑菇 (1)", "毒蘑菇 (2)", "毒蘑菇 (3)"])
        expectThrows(try NativeInstanceRecord.normalizedName("two\nlines"))
        expectThrows(try NativeInstanceRecord.normalizedName("bad\0name"))
        var record = NativeInstanceRecord(id: "sbx-test"); record.name = "名称 $(echo untouched)"
        let decoded = try JSON.decoder().decode(NativeInstanceRecord.self, from: JSON.data(record))
        expectEqual(decoded.name, record.name); expectEqual(decoded.id, record.id)
    }
    func pinnedDirectory() throws {
        let w = try workspace(), original = root.appendingPathComponent("work")
        try w.write(WorkspaceFile(path: "file", data: Data("pinned".utf8)))
        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: root)
        expectEqual(try w.read("file").data, Data("pinned".utf8))
    }
    func purgeWorkspace() throws {
        let w = try workspace(), path = root.appendingPathComponent("work")
        let outside = root.appendingPathComponent("outside")
        try SafeFiles.secureDirectory(outside)
        let canary = outside.appendingPathComponent("canary")
        try SafeFiles.writeData(Data("keep".utf8), to: canary)
        try w.write(WorkspaceFile(path: "nested/readonly/file", data: Data("delete".utf8)))
        expectEqual(chmod(path.appendingPathComponent("nested/readonly").path, 0o500), 0)
        try FileManager.default.createSymbolicLink(at: path.appendingPathComponent("symlink"), withDestinationURL: outside)
        expectEqual(link(canary.path, path.appendingPathComponent("hardlink").path), 0)
        expectEqual(mkfifo(path.appendingPathComponent("fifo").path, 0o600), 0)
        // Swapping the root path must not redirect the already-pinned FD.
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: path, to: moved)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        try w.removeAll()
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [])
        expectEqual(try SafeFiles.readRegular(canary, limit: 100), Data("keep".utf8))
        expectNoThrow(try w.removeAll())
        let aliases = moved.appendingPathComponent("metadata")
        try SafeFiles.secureDirectory(aliases)
        try FileManager.default.createSymbolicLink(atPath: aliases.appendingPathComponent("alias").path, withDestinationPath: "../../outside")
        try w.write(WorkspaceFile(path: "metadata/task", data: Data("delete".utf8)))
        try w.removeAll(preservingLinks: ["metadata/alias": "../../outside"])
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: aliases.path), ["alias"])
        expectThrows(try w.removeAll(preservingLinks: ["metadata/alias": "wrong-target"]))
        expectEqual(try SafeFiles.readRegular(canary, limit: 100), Data("keep".utf8))
    }
    func framing() throws {
        let a = Pipe(), b = Pipe()
        let sender = try FramedChannel(input: b.fileHandleForReading.fileDescriptor, output: a.fileHandleForWriting.fileDescriptor)
        let receiver = try FramedChannel(input: a.fileHandleForReading.fileDescriptor, output: b.fileHandleForWriting.fileDescriptor)
        let request = HostRequest(.info)
        try sender.send(request)
        expectEqual(try receiver.receive(HostRequest.self)?.id, request.id)
        expectThrows(try receiver.receive(HostRequest.self, timeout: 0.01))
        var size = UInt32(FramedChannel.messageLimit + 1).bigEndian
        try a.fileHandleForWriting.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) })
        expectThrows(try receiver.receive(HostRequest.self))
    }
    func leaseSerialization() throws {
        let scheduler = try ExecutionScheduler(coordinationDirectory: root.appendingPathComponent("leases"))
        let lock = NSLock(), group = DispatchGroup()
        var active = 0, maximum = 0, completed = 0, errors: [String] = []
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try scheduler.run { lease in
                        lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock()
                        usleep(15_000)
                        lock.lock(); active -= 1; completed += 1; lock.unlock()
                        return try syntheticResult(lease)
                    }
                } catch { lock.lock(); errors.append(String(describing: error)); lock.unlock() }
            }
        }
        expectEqual(group.wait(timeout: .now() + 5), .success)
        expectEqual(maximum, 1); expectEqual(completed, 4); expectTrue(errors.isEmpty)
        expectNil(scheduler.recoveryReason)
    }
    func networkPolicy() throws {
        let toolchain = try JSON.decoder().decode(InstalledClang.self, from: Data(#"{"compiler":"/tools/clang","cxxCompiler":"/tools/clang++","sdk":"/sdk"}"#.utf8))
        let offline = DevelopmentPolicy.hostEntitlements(identifier: "local.metal-sandbox.test", toolchain: toolchain)
        var online = DevelopmentPolicy.hostEntitlements(identifier: "local.metal-sandbox.test", toolchain: toolchain, networkClient: true)
        expectNil(offline["com.apple.security.network.client"])
        expectNil(online["com.apple.security.network.server"])
        expectEqual(online.removeValue(forKey: "com.apple.security.network.client") as? Bool, true)
        expectTrue(NSDictionary(dictionary: online).isEqual(to: offline))
    }
    func taskAllowlist() throws {
        for seconds in [0.01, 10, 7200, 172800, Double.greatestFiniteMagnitude] {
            try NativeCommand(["/bin/echo"], timeoutSeconds: seconds).validate()
        }
        for seconds in [0, -1, Double.infinity, Double.nan] {
            expectThrows(try NativeCommand(["/bin/echo"], timeoutSeconds: seconds).validate())
        }
        expectEqual(MonotonicDeadline.after(172800, now: 1), 172800_000_000_001)
        expectEqual(MonotonicDeadline.after(Double.greatestFiniteMagnitude, now: 1), UInt64.max)

        let toolchain = try JSON.decoder().decode(InstalledClang.self, from: Data(#"{"compiler":"/tools/clang","cxxCompiler":"/tools/clang++","sdk":"/sdk","cmake":"/tools/cmake","ninja":"/tools/ninja","buildToolsDirectory":"/tools","metalCompiler":"/tools/metal","metallib":"/tools/metallib"}"#.utf8))
        let defaults = try TaskPolicy.development(toolchain: toolchain)
        try defaults.validate()
        for tool in ["/bin/ls", "/bin/cat", "/bin/pwd", "/bin/sleep", "/bin/echo", "/bin/mkdir", "/bin/cp", "/bin/mv", "/bin/rm",
                     "/usr/bin/touch", "/usr/bin/head", "/usr/bin/tail", "/usr/bin/grep", "/usr/bin/sed", "/usr/bin/awk",
                     "/usr/bin/find", "/usr/bin/sort", "/usr/bin/wc", "/usr/bin/diff", "/usr/bin/git", "/tools/git",
                     "/usr/bin/make", "/tools/make", "/tools/ninja", "/tools/clang", "/tools/clang++", "/tools/metal", "/tools/metallib"] {
            expectTrue(defaults.allowsParallel(NativeCommand([tool])))
        }
        expectTrue(defaults.allowsParallel(NativeCommand(["/tools/cmake", "--build", "build", "--parallel", "4"])))
        expectFalse(defaults.allowsParallel(NativeCommand(["/tools/cmake", "-S", ".", "-B", "build"])))
        expectFalse(defaults.allowsParallel(NativeCommand(["/tools/cmake", "-E", "env", "./program"])))
        expectFalse(defaults.allowsParallel(NativeCommand(["/bin/sh", "-c", "make && ./program"])))
        expectFalse(defaults.allowsParallel(NativeCommand(["./make"])))
        for wrapper in ["/bin/bash", "/bin/zsh", "/usr/bin/env", "/usr/bin/xargs", "/usr/bin/python3", "/usr/bin/node"] {
            expectFalse(defaults.allowsParallel(NativeCommand([wrapper])))
        }
        let policy = TaskPolicy(parallel: [.init("/bin/ls"), .init("/tools/cmake", argumentPrefix: ["--build"])])
        try policy.validate()
        expectTrue(policy.allowsParallel(NativeCommand(["/bin/ls", "-la"])))
        expectTrue(policy.allowsParallel(NativeCommand(["/tools/cmake", "--build", "build"])))
        for argv in [["./ls"], ["/other/ls"], ["/bin/sh", "-c", "ls; ./gpu"],
                     ["/tools/cmake", "--buildx"], ["/tools/cmake", "-S", "."], ["/usr/bin/env", "/bin/ls"]] {
            expectFalse(policy.allowsParallel(NativeCommand(argv)))
        }
        expectThrows(try TaskPolicy(parallel: [.init("ls")]).validate())
        expectThrows(try TaskPolicy(parallel: [.init("/bin/../bin/ls")]).validate())
        let decoded = try JSON.decoder().decode(TaskPolicy.self, from: Data("{\"parallel\":[{\"executable\":\"/bin/cat\"}]}".utf8))
        expectTrue(decoded.allowsParallel(NativeCommand(["/bin/cat", "file"])))
        let blocklist = TaskPolicy(serial: [.init("/bin/cat"), .init("/tools/cmake", argumentPrefix: ["--build"])])
        try blocklist.validate()
        expectFalse(blocklist.allowsParallel(NativeCommand(["/bin/cat", "file"])))
        expectFalse(blocklist.allowsParallel(NativeCommand(["/tools/cmake", "--build", "build"])))
        for argv in [["/bin/ls"], ["/tools/cmake", "--buildx"], ["/tools/cmake", "-S", "."], ["/bin/sh", "-c", "cat file"]] {
            expectTrue(blocklist.allowsParallel(NativeCommand(argv)))
        }
        expectFalse(blocklist.allowsParallel(nil))
        expectFalse(blocklist.allowsParallel(NativeCommand([])))
        expectTrue(TaskPolicy(serial: []).allowsParallel(NativeCommand(["/bin/cat"])))
        expectFalse(TaskPolicy().allowsParallel(NativeCommand(["/bin/cat"])))
        let restoredBlocklist = try JSON.decoder().decode(TaskPolicy.self, from: JSON.encoder().encode(blocklist))
        expectEqual(restoredBlocklist.mode, .blocklist)
        expectFalse(restoredBlocklist.allowsParallel(NativeCommand(["/bin/cat"])))
        expectTrue(restoredBlocklist.allowsParallel(NativeCommand(["/bin/ls"])))
        expectThrows(try TaskPolicy(serial: [.init("cat")]).validate())
        for invalid in [#"{"parallel":[],"typo":true}"#, #"{"parallel":[{"executable":"/bin/cat","argumentprefix":["--help"]}]}"#,
                        #"{"parallel":[{"executable":"/bin/cat","argumentPrefix":null}]}"#, #"{"parallel":"all"}"#,
                        #"{"parallel":[],"serial":[]}"#, #"{"serial":null}"#, #"{"serial":[],"typo":true}"#, #"{}"#] {
            expectThrows(try JSON.decoder().decode(TaskPolicy.self, from: Data(invalid.utf8)))
        }
        let minimal = try JSON.decoder().decode(InstalledClang.self, from: Data(#"{"compiler":"/tools/clang","cxxCompiler":"/tools/clang++","sdk":"/sdk"}"#.utf8))
        let minimalPolicy = try TaskPolicy.development(toolchain: minimal)
        expectFalse(minimalPolicy.rules.contains { $0.executable.contains("${") })
        expectFalse(minimalPolicy.allowsParallel(NativeCommand(["/tools/ninja"])))
    }
    func compoundShellTaskPolicy() throws {
        let toolchain = try JSON.decoder().decode(InstalledClang.self, from: Data(#"{"compiler":"/tools/clang","cxxCompiler":"/tools/clang++","sdk":"/sdk"}"#.utf8))
        var policy = try TaskPolicy.development(toolchain: toolchain)
        let environment = ["PATH": "/usr/bin:/bin"]
        func parallel(_ script: String, shell: String = "/bin/bash", env: [String: String]? = nil) -> Bool {
            policy.allowsParallel(NativeCommand([shell, "-c", script]), shellEnvironment: env ?? environment, workingDirectory: root.path)
        }
        for script in ["ls && cat file", "false || echo fallback", "printf '%s' 'a;|&&' | wc -c", "sleep 1; echo done\nls",
                       "echo '' \"quoted;|value\"", "ls # comment && ./gpu\ncat file", "ls &&\ncat file",
                       "echo hello > out; cat < out; echo error 1>&2", "echo 2>>out; cat out", "echo '#'",
                       "ls \\\n&& cat file", "/bin/bash -c 'ls && cat file'; /bin/echo done"] {
            expectTrue(parallel(script))
        }
        for script in ["ls && ./gpu", "./gpu || ls", "ls | ./gpu", "ls\n./gpu", "ls; ./make",
                       "echo $(./gpu); ls", "echo `./gpu`", "echo \"$COMMAND\"", "$COMMAND; ls", "echo *.metal", "echo ~",
                       "PATH=/other ls; cat f", "export PATH=/other; ls", "cd subdir && ls", "eval ls", "command ls",
                       "echo x > >(./gpu)", "cat <<EOF\n./gpu\nEOF", "ls & cat f", "(ls; cat f)", "ls; { cat f; }",
                       "f() { ls; }; f", "if true; then ls; fi", "ls; ; cat f", "ls &&", "ls || | cat", "ls >",
                       "ls '", "ls \\", "", "# comment", "printf -v PATH /other; ls", "printf %n PATH; ls", "printf '%1n' PATH; ls", "printf '%+n' PATH; ls", "printf '%ln' PATH; ls", "echo safe\r\n./gpu",
                       "/bin/bash -lc 'ls'", "/bin/bash script.sh", "echo safe; /bin/zsh -c 'ls'", "ls 2>&file"] {
            expectFalse(parallel(script))
        }
        expectEqual(shellCommandList(#"echo "a\q" '' 'x;y'"#)!, [["echo", "a\\q", "", "x;y"]])
        expectEqual(shellCommandList("echo 2>file; echo '2'>file")!, [["echo"], ["echo", "2"]])
        expectFalse(parallel("ls", shell: "/bin/zsh"))
        expectFalse(parallel("ls", env: environment.merging(["BASH_ENV": "startup.sh"]) { _, v in v }))
        expectFalse(parallel("ls", env: environment.merging(["BASH_FUNC_ls%%": "() { ./gpu; }"]) { _, v in v }))
        // A shell rule cannot override a missing inner command or dynamic syntax.
        policy.rules.append(.init("/bin/bash"))
        expectFalse(parallel("ls && ./gpu")); expectFalse(parallel("$COMMAND"))
        // Resolve from the sandbox's PATH/cwd, not a tool basename or host PATH.
        let tools = root.appendingPathComponent("tools")
        try SafeFiles.secureDirectory(tools)
        for name in ["ls", "cmake"] {
            let file = tools.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let env = ["PATH": "tools:/usr/bin:/bin"]
        expectFalse(parallel("ls && cat file", env: env))
        expectNil(shellExecutable("ls", environment: env, cwd: root.path))
        expectNil(shellExecutable("ls", environment: ["PATH": ":/bin"], cwd: tools.path))
        expectNil(shellExecutable("tools/../ls", environment: env, cwd: root.path))
        policy.rules.append(.init(tools.appendingPathComponent("cmake").path, argumentPrefix: ["--build"]))
        expectTrue(parallel("\(tools.path)/cmake --build build && cat file"))
        expectFalse(parallel("\(tools.path)/cmake -S . && cat file"))
        expectFalse(parallel("\(tools.path)/cmake --buildx build && cat file"))
        try FileManager.default.removeItem(at: tools.appendingPathComponent("ls"))
        expectFalse(parallel("cp ./gpu tools/ls; ls", env: env))
        expectFalse(parallel("cp ./gpu tools/ls; ls", env: ["PATH": tools.path + ":/usr/bin:/bin"]))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("tools_link").path, withDestinationPath: "/bin")
        expectFalse(parallel("/bin/rm tools_link; /bin/mkdir tools_link; /bin/cp ./gpu tools_link/make; make", env: ["PATH": "tools_link:/usr/bin:/bin"]))
        // Managed tools can live under the operator's home without being
        // writable by the sandbox. Only the actual container is a mutable root.
        let layout = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/metal_sandbox_path_test_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: layout) }
        let controllerTools = layout.appendingPathComponent("managed_tools")
        let container = layout.appendingPathComponent("container/Data")
        let base = container.appendingPathComponent("Library/Application Support/MetalSandbox")
        let workspace = base.appendingPathComponent("workspace/subdir")
        let privateHome = base.appendingPathComponent("home"), temporary = base.appendingPathComponent("tmp")
        for directory in [controllerTools, workspace, privateHome, temporary] { try SafeFiles.secureDirectory(directory) }
        let managedEnvironment = ["PATH": controllerTools.path + ":/usr/bin:/bin", "HOME": privateHome.path,
                                  "TMPDIR": temporary.path, "METAL_SANDBOX_BRIDGE_DIRECTORY": temporary.path,
                                  "METAL_SANDBOX_CONTAINER_HOME": container.path]
        for script in ["ls", "cat file", "ls && cat file", "/bin/ls && /bin/cat file"] {
            expectTrue(policy.allowsParallel(NativeCommand(["/bin/bash", "-c", script]),
                shellEnvironment: managedEnvironment, workingDirectory: workspace.path))
        }
        expectEqual(shellExecutable("cat", environment: managedEnvironment, cwd: workspace.path), "/bin/cat")
        // Protect private PATH entries even when empty, or reached via a
        // symlink from a controller directory, and when cwd is a subdirectory.
        for directory in [container.appendingPathComponent("Documents/bin"), base.appendingPathComponent("workspace/bin"),
                          privateHome.appendingPathComponent("bin"), temporary.appendingPathComponent("bin")] {
            try SafeFiles.secureDirectory(directory)
            let env = managedEnvironment.merging(["PATH": directory.path + ":/usr/bin:/bin"]) { _, value in value }
            expectNil(shellExecutable("cat", environment: env, cwd: workspace.path))
        }
        let privateLink = controllerTools.appendingPathComponent("private_link")
        try FileManager.default.createSymbolicLink(at: privateLink, withDestinationURL: privateHome)
        let linkedEnvironment = managedEnvironment.merging(["PATH": privateLink.path + ":/usr/bin:/bin"]) { _, value in value }
        expectNil(shellExecutable("cat", environment: linkedEnvironment, cwd: workspace.path))
        let otherCat = controllerTools.appendingPathComponent("cat")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: otherCat)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: otherCat.path)
        expectFalse(policy.allowsParallel(NativeCommand(["/bin/bash", "-c", "cat file"]),
            shellEnvironment: managedEnvironment, workingDirectory: workspace.path))
        let blacklist = TaskPolicy(serial: [.init("/bin/sh")])
        expectFalse(blacklist.allowsParallel(NativeCommand(["/bin/sh", "-c", "ls && cat file"]), shellEnvironment: environment, workingDirectory: root.path))
        expectTrue(blacklist.allowsParallel(NativeCommand(["/bin/bash", "-c", "ls && ./gpu"]), shellEnvironment: environment, workingDirectory: root.path))
    }
    func parallelAllowlistLeases() throws {
        let policy = TaskPolicy(parallel: [.init("/bin/cat")])
        let scheduler = try ExecutionScheduler(coordinationDirectory: root.appendingPathComponent("leases"), taskPolicy: policy)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let group = DispatchGroup(), lock = NSLock()
        var errors: [String] = []
        // Keep one serial task active. Two allowlisted tasks must start before
        // it finishes, rather than merely reporting their submissions early.
        for (argv, override) in [(["/bin/cat"], TaskPolicy()), (["/bin/cat"], policy), (["/bin/sleep", "1"], TaskPolicy(parallel: [.init("/bin/sleep")]))] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try scheduler.run(command: NativeCommand(argv), taskPolicy: override) { lease in
                        entered.signal()
                        guard release.wait(timeout: .now() + 5) == .success else { throw SandboxError("parallel launch barrier timed out") }
                        return try syntheticResult(lease)
                    }
                } catch { lock.lock(); errors.append(String(describing: error)); lock.unlock() }
            }
        }
        for _ in 0..<3 { expectEqual(entered.wait(timeout: .now() + 3), .success) }
        let markers = root.appendingPathComponent("leases/parallel_leases")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: markers.path).count, 2)
        for _ in 0..<3 { release.signal() }
        expectEqual(group.wait(timeout: .now() + 5), .success)
        expectTrue(errors.isEmpty); expectNil(scheduler.recoveryReason)
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: markers.path).count, 0)
    }
    func executionCountBreakdown() throws {
        let thermalLock = NSLock()
        var thermal: ProcessInfo.ThermalState = .nominal
        let scheduler = try ExecutionScheduler(coordinationDirectory: root.appendingPathComponent("counts"), thermalState: {
            thermalLock.lock(); defer { thermalLock.unlock() }; return thermal
        })
        let running = DispatchGroup(), waiting = DispatchGroup()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let parent = CancellationToken(), parallelWaiter = CancellationToken(), serialWaiter = CancellationToken()
        defer {
            parallelWaiter.cancel(); serialWaiter.cancel(); release.signal(); release.signal()
            _ = running.wait(timeout: .now() + 3); _ = waiting.wait(timeout: .now() + 3)
        }
        scheduler.registerPending(parent, ownerID: "logical-a", parallel: true)
        expectEqual(scheduler.counts.total, ExecutionCounts(parallelWaiting: 1))
        for (parallel, token) in [(true, parent), (false, CancellationToken())] {
            running.enter()
            DispatchQueue.global().async {
                defer { running.leave() }
                do {
                    _ = try scheduler.run(parallel: parallel, cancellation: token, ownerID: "physical-a") { lease in
                        entered.signal()
                        guard release.wait(timeout: .now() + 5) == .success else { throw SandboxError("count fixture not released") }
                        return try syntheticResult(lease)
                    }
                } catch { fail("count fixture: \(error)") }
            }
        }
        for _ in 0..<2 { expectEqual(entered.wait(timeout: .now() + 2), .success) }
        let active = scheduler.counts
        expectEqual(active.total, ExecutionCounts(parallelRunning: 1, serialRunning: 1))
        expectEqual(active.byOwner["logical-a"], ExecutionCounts(parallelRunning: 1))
        expectEqual(active.byOwner["physical-a"], ExecutionCounts(serialRunning: 1))
        thermalLock.lock(); thermal = .critical; thermalLock.unlock()
        for (parallel, token) in [(true, parallelWaiter), (false, serialWaiter)] {
            waiting.enter()
            DispatchQueue.global().async {
                defer { waiting.leave() }
                do {
                    _ = try scheduler.run(parallel: parallel, cancellation: token, ownerID: "physical-b", parentID: "parent") {
                        fail("waiting count fixture launched"); return try syntheticResult($0)
                    }
                } catch {}
            }
        }
        let expected = ExecutionCounts(parallelRunning: 1, parallelWaiting: 1, serialRunning: 1, serialWaiting: 1)
        let end = Date().addingTimeInterval(2)
        while scheduler.counts.total != expected && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        let all = scheduler.counts
        expectEqual(all.total, expected); expectEqual(all.total.total, 4)
        expectEqual(all.byOwner.values.reduce(ExecutionCounts(), +), expected)
        parallelWaiter.cancel(); serialWaiter.cancel()
        expectEqual(waiting.wait(timeout: .now() + 2), .success)
        expectEqual(scheduler.counts.total, active.total)
        release.signal(); release.signal()
        expectEqual(running.wait(timeout: .now() + 2), .success)
        scheduler.discardPending(parent) // Consumed registrations must not double-decrement.
        expectEqual(scheduler.counts.total, ExecutionCounts())
        let discarded = CancellationToken()
        scheduler.registerPending(discarded, ownerID: "logical-c", parallel: false)
        expectEqual(scheduler.counts.total, ExecutionCounts(serialWaiting: 1))
        scheduler.discardPending(discarded)
        expectEqual(scheduler.counts.total.total, 0)
    }
    func queuedDeadlineAndLifecycle() throws {
        let scheduler = try ExecutionScheduler(coordinationDirectory: root.appendingPathComponent("deadline"))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { completed.signal() }
            _ = try? scheduler.run { lease in
                entered.signal(); _ = release.wait(timeout: .now() + 5)
                return try syntheticResult(lease)
            }
        }
        defer { release.signal(); _ = completed.wait(timeout: .now() + 3) }
        expectEqual(entered.wait(timeout: .now() + 2), .success)
        let start = Date()
        var launched = false
        expectThrows(try scheduler.run(deadlineUptimeNanoseconds: MonotonicDeadline.after(0.3)) {
            launched = true; return try syntheticResult($0)
        })
        expectFalse(launched)
        expectTrue(Date().timeIntervalSince(start) < 1)
        expectEqual(scheduler.pendingCount, 1)
        expectNil(scheduler.recoveryReason)
        var record = NativeInstanceRecord(id: "sbx-test")
        record.state = .failed
        expectTrue(record.actions(isLive: true).contains(.stop))
        expectFalse(record.actions(isLive: false).contains(.stop))
        expectFalse(record.actions(isLive: true).contains(.delete))
        expectTrue(record.actions(isLive: false).contains(.delete))
        var reply = NativeControlReply(requestID: "test")
        reply.ok = false; reply.error = "wording may change"; reply.errorCode = .instanceInactive
        expectEqual(try JSON.decoder().decode(NativeControlReply.self, from: JSON.data(reply)).errorCode, .instanceInactive)
        expectEqual(NativeControlRequest("stop").responseTimeout, .infinity)
        expectEqual(NativeControlRequest("status").responseTimeout, 1920)
    }
    func parallelLeaseRecovery() throws {
        let directory = root.appendingPathComponent("leases")
        let policy = TaskPolicy(parallel: [.init("/bin/cat")])
        var scheduler: ExecutionScheduler? = try ExecutionScheduler(coordinationDirectory: directory, taskPolicy: policy)
        expectThrows(try scheduler!.run(command: NativeCommand(["/bin/cat"])) { try syntheticResult($0, reason: "timedOut", processGroupGone: false) })
        scheduler = nil
        let reopened = try ExecutionScheduler(coordinationDirectory: directory, taskPolicy: policy)
        expectTrue(reopened.recoveryReason != nil)
        expectThrows(try reopened.run(command: NativeCommand(["/bin/cat"]), deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 250_000_000) { try syntheticResult($0) })
        try reopened.acknowledgeRecovery(confirmed: true, note: "Unit fixture, no real process or GPU")
        expectNil(reopened.recoveryReason)
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("parallel_leases").path).count, 0)
        expectNoThrow(try reopened.run(command: NativeCommand(["/bin/cat"])) { try syntheticResult($0) })
    }
    func quarantine() throws {
        let directory = root.appendingPathComponent("leases")
        let scheduler = try ExecutionScheduler(coordinationDirectory: directory)
        expectThrows(try scheduler.run { try syntheticResult($0, reason: "timedOut", processGroupGone: false) })
        var launched = false
        expectThrows(try scheduler.run(deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 250_000_000) { launched = true; return try syntheticResult($0) })
        expectFalse(launched)
        expectTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("active-lease.json").path))
        expectTrue(scheduler.recoveryReason != nil)
    }
    func interruptionCleanup() throws {
        for (reason, parallel) in ["timedOut", "cancelled", "signalled", "outputLimit"].flatMap({ reason in [false, true].map { (reason, $0) } }) {
            let directory = root.appendingPathComponent(reason + (parallel ? "_parallel" : "_serial"))
            let policy = TaskPolicy(parallel: parallel ? [.init("/bin/sleep")] : [])
            var scheduler: ExecutionScheduler? = try ExecutionScheduler(coordinationDirectory: directory, taskPolicy: policy)
            // An interruption stays an interruption even if its handler exits zero.
            let result = try scheduler!.run(command: NativeCommand(["/bin/sleep", "5"])) {
                try syntheticResult($0, reason: reason, exitCode: 0)
            }
            expectEqual(result.outcome.reason.rawValue, reason)
            expectNil(scheduler!.recoveryReason)
            expectNoThrow(try scheduler!.run { try syntheticResult($0) })
            expectFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("active-lease.json").path))
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("parallel_leases").path), [])
            scheduler = nil
            let reopened = try ExecutionScheduler(coordinationDirectory: directory, taskPolicy: policy)
            expectNil(reopened.recoveryReason)
            expectNoThrow(try reopened.run { try syntheticResult($0) })
        }
        // Every result, even exit zero, still requires confirmed cleanup.
        for reason in ["exited", "timedOut", "cancelled", "signalled", "outputLimit"] {
            let scheduler = try ExecutionScheduler(coordinationDirectory: root.appendingPathComponent(reason))
            expectThrows(try scheduler.run { try syntheticResult($0, reason: reason, processGroupGone: false) })
            expectTrue(scheduler.recoveryReason != nil)
        }
    }
    func thermalPause() throws {
        let lock = NSLock()
        var thermal: ProcessInfo.ThermalState = .critical
        func temperature(_ value: ProcessInfo.ThermalState) { lock.lock(); thermal = value; lock.unlock() }
        let directory = root.appendingPathComponent("thermal")
        let scheduler = try ExecutionScheduler(coordinationDirectory: directory, thermalState: {
            lock.lock(); defer { lock.unlock() }; return thermal
        })
        for parallel in [false, true] {
            temperature(.critical)
            let launched = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { done.signal() }
                do { _ = try scheduler.run(parallel: parallel) { launched.signal(); return try syntheticResult($0) } }
                catch { fail("cooldown execution: \(error)") }
            }
            expectEqual(launched.wait(timeout: .now() + 0.2), .timedOut)
            expectEqual(scheduler.counts.total, parallel ? ExecutionCounts(parallelWaiting: 1) : ExecutionCounts(serialWaiting: 1))
            expectNil(scheduler.recoveryReason)
            expectFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("active-lease.json").path))
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("parallel_leases").path), [])
            temperature(.serious)
            expectEqual(launched.wait(timeout: .now() + 3), .success)
            expectEqual(done.wait(timeout: .now() + 3), .success)
        }
        // Heating up after launch cannot turn a completed task into a node fault.
        expectNoThrow(try scheduler.run { temperature(.critical); return try syntheticResult($0) })
        expectNil(scheduler.recoveryReason)
        let token = CancellationToken(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                _ = try scheduler.run(cancellation: token) { fail("cancelled hot task launched"); return try syntheticResult($0) }
                fail("hot task ignored cancellation")
            } catch {}
        }
        Thread.sleep(forTimeInterval: 0.15); token.cancel()
        expectEqual(done.wait(timeout: .now() + 3), .success)
        expectThrows(try scheduler.run(deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 250_000_000) {
            fail("expired hot task launched"); return try syntheticResult($0)
        })
        expectNil(scheduler.recoveryReason); expectEqual(scheduler.pendingCount, 0)
        temperature(.nominal)
        expectThrows(try scheduler.run { try syntheticResult($0, processGroupGone: false) })
        temperature(.critical); temperature(.nominal)
        expectTrue(scheduler.recoveryReason != nil)
        expectThrows(try scheduler.run(deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 250_000_000) { fail("cooldown cleared quarantine"); return try syntheticResult($0) })
    }
    func cancellationAndStaleLease() throws {
        let directory = root.appendingPathComponent("leases")
        var scheduler: ExecutionScheduler? = try ExecutionScheduler(coordinationDirectory: directory)
        let token = CancellationToken(); token.cancel()
        var launched = false
        expectThrows(try scheduler!.run(cancellation: token) { launched = true; return try syntheticResult($0) })
        expectFalse(launched); expectNil(scheduler!.recoveryReason)
        expectThrows(try scheduler!.run(deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) {
            launched = true; return try syntheticResult($0)
        })
        expectFalse(launched); expectNil(scheduler!.recoveryReason)
        scheduler = nil
        try SafeFiles.writeData(Data("stale".utf8), to: directory.appendingPathComponent("active-lease.json"))
        let reopened = try ExecutionScheduler(coordinationDirectory: directory)
        expectThrows(try reopened.run(deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 250_000_000) { try syntheticResult($0) })
    }
    func artifacts() throws {
        let store = try ArtifactStore(directory: root.appendingPathComponent("artifacts"))
        let file = WorkspaceFile(path: "src/a.c", data: Data("snapshot".utf8))
        let artifact = try store.freeze([file])
        expectEqual(try store.freeze([file]).id, artifact.id)
        expectEqual(try store.load(artifact.id).files, [file])
        expectThrows(try store.load("../../escape"))
        expectThrows(try store.freeze([file, file]))
        expectThrows(try store.freeze([WorkspaceFile(path: "SRC/A.c", data: Data()), file]))
        expectThrows(try store.freeze([WorkspaceFile(path: "src", data: Data()), file]))
        try SafeFiles.writeData(Data("tampered".utf8), to: root.appendingPathComponent("artifacts/\(artifact.id).json"))
        expectThrows(try store.load(artifact.id))
    }
    func scopedRegistry() throws {
        let registry = SandboxRegistry(), a = MemorySandbox("a"), b = MemorySandbox("b")
        let owner = try registry.register(a), other = try registry.register(b)
        expectThrows(try registry.register(a))
        let writer = registry.client(owner)
        try writer.write(WorkspaceFile(path: "secret", data: Data("A".utf8)))
        let readerHandle = try registry.grant(owner, operations: [.read])
        let reader = registry.client(readerHandle)
        expectEqual(try reader.read("secret").data, Data("A".utf8))
        expectEqual(try reader.listDirectory(".", after: nil).path, ".")
        let writeOnly = try registry.grant(owner, operations: [.write])
        expectThrows(try registry.client(writeOnly).listDirectory(".", after: nil))
        expectThrows(try reader.write(WorkspaceFile(path: "secret", data: Data())))
        expectThrows(try reader.execute(NativeCommand(["/bin/echo", "bypass"])))
        expectThrows(try registry.grant(readerHandle, operations: [.exec]))
        let forged = SandboxHandle(instanceID: "a", generation: owner.generation, capability: other.capability)
        expectThrows(try registry.client(forged).read("secret"))
        let stale = SandboxHandle(instanceID: "a", generation: "wrong-generation", capability: owner.capability)
        expectThrows(try registry.client(stale).read("secret"))
        expectThrows(try registry.client(forged).listDirectory(".", after: nil))
        expectThrows(try registry.client(stale).listDirectory(".", after: nil))
        try writer.close()
        expectThrows(try reader.listDirectory(".", after: nil))
        expectThrows(try reader.read("secret")); expectThrows(try registry.register(a))
        expectTrue(a.closed); expectFalse(b.closed)
        let restarted = MemorySandbox("a")
        let fresh = try registry.register(restarted, reactivating: true)
        expectFalse(fresh.generation == owner.generation)
        expectFalse(fresh.capability == owner.capability)
        expectThrows(try registry.register(MemorySandbox("a"), reactivating: true))
        expectThrows(try reader.read("secret"))
        expectThrows(try registry.client(owner).close())
        let current = registry.client(fresh)
        try current.write(WorkspaceFile(path: "secret", data: Data("new generation".utf8)))
        expectEqual(try current.read("secret").data, Data("new generation".utf8))
        try current.close()
    }
    func readsDuringExecution() throws {
        let registry = SandboxRegistry(), memory = MemorySandbox("live")
        let owner = try registry.register(memory), client = registry.client(owner)
        let reader = registry.client(try registry.grant(owner, operations: [.read]))
        let file = WorkspaceFile(path: "visible.txt", data: Data("live file".utf8))
        try client.write(file)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        memory.executionStarted = started; memory.executionRelease = release
        let group = DispatchGroup(), errorsLock = NSLock()
        var error: Error?
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { _ = try client.execute(NativeCommand(["/bin/sleep", "1"])) }
            catch let caught { errorsLock.lock(); error = caught; errorsLock.unlock() }
        }
        defer { release.signal(); group.wait() }
        expectEqual(started.wait(timeout: .now() + 2), .success)
        expectEqual(try reader.listDirectory(".", after: nil).path, ".")
        expectEqual(try reader.read(file.path), file)
        let archive = root.appendingPathComponent("live_file.zip")
        try reader.download(to: archive, path: file.path)
        expectEqual(try WorkspaceArchive.collect(archive), [file])
        expectEqual(group.wait(timeout: .now()), .timedOut)
        expectThrows(try client.write(WorkspaceFile(path: file.path, data: Data())))
        expectThrows(try client.upload(from: archive))
        expectThrows(try client.export())
        expectThrows(try client.download(to: root.appendingPathComponent("snapshot.zip"), path: nil))
        release.signal()
        expectEqual(group.wait(timeout: .now() + 2), .success)
        errorsLock.lock(); let caught = error; errorsLock.unlock()
        expectNil(caught)
        expectEqual(try client.export(), [file])
        try client.close()
        expectThrows(try reader.read(file.path))
    }
    func episode() throws {
        let store = try ArtifactStore(directory: root.appendingPathComponent("artifacts"))
        let controller = try EpisodeController(directory: root.appendingPathComponent("episodes"), store: store)
        let working = MemorySandbox("working"), fresh = MemorySandbox("fresh")
        var agent = ScriptedAgent([
            .write(WorkspaceFile(path: "fixture_main.c", data: Data("broken".utf8))),
            .exec(NativeCommand(["/usr/bin/clang", "fixture_main.c"])),
            .write(WorkspaceFile(path: "fixture_main.c", data: Data("fixed".utf8))),
            .exec(NativeCommand(["/usr/bin/clang", "fixture_main.c"])), .finish,
        ])
        let result = try controller.run(agent: &agent, working: working, makeVerifierSandbox: { frozen in
            expectTrue(working.closed)
            expectTrue(frozen.files.contains { $0.path == "fixture_main.c" })
            return fresh
        },
            verifier: OutputVerifier(command: NativeCommand(["./fixture_program"]), expected: Data("42\n".utf8)))
        expectEqual(result.state, "succeeded"); expectEqual(result.turns, 4)
        expectTrue(result.verification?.correctness == true)
        expectTrue(working.closed && fresh.closed)
        expectEqual(try store.load(unwrap(result.artifactID)).files, try fresh.export())
        expectEqual(fresh.commands.count, 1)
        expectTrue(fresh.commands[0].deadlineUptimeNanoseconds != nil)
        let trace = try String(contentsOf: root.appendingPathComponent("episodes/\(result.id)/trace.jsonl"), encoding: .utf8)
        expectTrue(trace.contains(Data("compile error\n".utf8).base64EncodedString())); expectTrue(trace.contains("artifact-frozen"))
        let events = try trace.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let compileEvent = events.first { ($0["observation"] as? [String: Any])?["kind"] as? String == "exec" }
        let command = (compileEvent?["observation"] as? [String: Any])?["command"] as? [String: Any]
        expectEqual(command?["argv"] as? [String], ["/usr/bin/clang", "fixture_main.c"])
        let eventNames = events.compactMap { $0["event"] as? String }
        expectTrue(try unwrap(eventNames.firstIndex(of: "artifact-frozen")) < unwrap(eventNames.firstIndex(of: "working-stopped")))
    }
    func episodeGuards() throws {
        let store = try ArtifactStore(directory: root.appendingPathComponent("artifacts"))
        let controller = try EpisodeController(directory: root.appendingPathComponent("episodes"), store: store)
        let verifier = OutputVerifier(command: NativeCommand(["./fixture_program"]), expected: Data("42\n".utf8))
        for dirty in [false, true] {
            let working = MemorySandbox("same"), fresh = MemorySandbox(dirty ? "fresh" : "same")
            if dirty { fresh.files["stale"] = WorkspaceFile(path: "stale", data: Data()) }
            var agent = ScriptedAgent([.finish])
            let report = try controller.run(agent: &agent, working: working, makeVerifierSandbox: { _ in fresh }, verifier: verifier)
            expectEqual(report.state, "failed"); expectTrue(fresh.commands.isEmpty)
        }
        let working = MemorySandbox("working"), fresh = MemorySandbox("fresh")
        fresh.failClose = true
        var agent = ScriptedAgent([.finish])
        let report = try controller.run(agent: &agent, working: working, makeVerifierSandbox: { _ in fresh }, verifier: verifier)
        expectEqual(report.state, "failed"); expectTrue(report.error?.contains("cleanup") == true)
    }

    func publicationInput() throws {
        var header = Data(repeating: 0, count: 32)
        header.replaceSubrange(0..<4, with: [0xcf, 0xfa, 0xed, 0xfe])
        header[12] = 2
        let file = WorkspaceFile(path: "build/fixture_program", data: header, executable: true)
        expectNoThrow(try PublishedCandidate.validate(file)) // Precheck only, not a valid signed Mach-O.
        expectThrows(try PublishedCandidate.validate(WorkspaceFile(path: "../fixture_program", data: header, executable: true)))
        expectThrows(try PublishedCandidate.validate(WorkspaceFile(path: "fixture_program", data: header)))
        expectThrows(try PublishedCandidate.validate(WorkspaceFile(path: "fixture_program", data: Data("#!/bin/sh\necho hi".utf8), executable: true)))
        header[12] = 6 // MH_DYLIB
        expectThrows(try PublishedCandidate.validate(WorkspaceFile(path: "fixture_program", data: header, executable: true)))
        header[12] = 2; header.append(Data(count: 5 * 1024 * 1024))
        expectNoThrow(try PublishedCandidate.validate(WorkspaceFile(path: "fixture_program", data: header, executable: true)))
    }

    func freezeCloseFailure() throws {
        let store = try ArtifactStore(directory: root.appendingPathComponent("artifacts"))
        let controller = try EpisodeController(directory: root.appendingPathComponent("episodes"), store: store)
        let working = MemorySandbox("working")
        working.failClose = true
        var published = false
        var agent = ScriptedAgent([.finish])
        let report = try controller.run(agent: &agent, working: working, makeVerifierSandbox: { _ in
            published = true; return MemorySandbox("fresh")
        }, verifier: OutputVerifier(command: NativeCommand(["./fixture_program"]), expected: Data()))
        expectEqual(report.state, "failed"); expectFalse(published)
        expectTrue(report.artifactID != nil)
    }

    func concurrentFrames() throws {
        let pipe = Pipe(), reverse = Pipe()
        let sender = try FramedChannel(input: reverse.fileHandleForReading.fileDescriptor, output: pipe.fileHandleForWriting.fileDescriptor)
        let receiver = try FramedChannel(input: pipe.fileHandleForReading.fileDescriptor, output: reverse.fileHandleForWriting.fileDescriptor)
        let group = DispatchGroup(), lock = NSLock()
        var errors: [String] = []
        let requests = (0..<40).map { _ in HostRequest(.info) }
        for request in requests {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { try sender.send(request) }
                catch { lock.lock(); errors.append(String(describing: error)); lock.unlock() }
            }
        }
        var ids = Set<String>()
        for _ in requests { ids.insert(try unwrap(receiver.receive(HostRequest.self, timeout: 5)).id) }
        expectEqual(group.wait(timeout: .now() + 5), .success)
        expectEqual(ids, Set(requests.map { $0.id })); expectTrue(errors.isEmpty)
    }

    func explicitRecovery() throws {
        let path = root.appendingPathComponent("leases")
        let scheduler = try ExecutionScheduler(coordinationDirectory: path)
        expectThrows(try scheduler.run { try syntheticResult($0, reason: "cancelled", processGroupGone: false) })
        expectThrows(try scheduler.acknowledgeRecovery(confirmed: false, note: "test"))
        expectThrows(try scheduler.acknowledgeRecovery(confirmed: true, note: ""))
        try scheduler.acknowledgeRecovery(confirmed: true, note: "synthetic unit result only; no process or GPU launched")
        expectNil(scheduler.recoveryReason)
        expectFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("active-lease.json").path))
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: path.appendingPathComponent("recovery_history").path).count, 2)
        expectNoThrow(try scheduler.run { try syntheticResult($0) })
    }
}
