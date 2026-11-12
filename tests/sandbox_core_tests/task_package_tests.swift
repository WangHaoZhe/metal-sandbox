import Foundation
import Darwin
import SandboxCore
import SandboxRuntime

extension RuntimeTests {
    func verificationPackages() throws {
        let source = root.appendingPathComponent("verification task")
        try SafeFiles.secureDirectory(source)
        let workspace = try ConfinedWorkspace(directory: source)
        for path in ["agent/instruction.md", "agent/setup.sh", "agent/answer/keep.cpp", "tests/test.sh", "tests/helper.swift"] {
            try workspace.write(WorkspaceFile(path: path, data: Data((path + "\n").utf8)))
        }
        let output = root.appendingPathComponent("tests.zip")
        try TaskPackage.prepareTests(source, to: output)
        expectEqual(try WorkspaceArchive.collect(output).map(\.path), ["tests/helper.swift", "tests/test.sh"])
        let original = try WorkspaceArchive.digest(output)
        try workspace.write(WorkspaceFile(path: "tests/test.sh", data: Data()))
        expectThrows(try TaskPackage.prepareTests(source, to: output))
        expectEqual(try WorkspaceArchive.digest(output), original)
        try workspace.write(WorkspaceFile(path: "tests/test.sh", data: Data("exit 0\n".utf8)))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("tests/alias").path, withDestinationPath: "test.sh")
        expectThrows(try TaskPackage.prepareTests(source, to: output))
        expectEqual(try WorkspaceArchive.digest(output), original)
        try FileManager.default.removeItem(at: source.appendingPathComponent("tests"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("tests").path, withDestinationPath: "answer")
        expectThrows(try TaskPackage.prepareTests(source, to: output))
        var command = NativeCommand(["/bin/bash", "./test.sh"], cwd: "tests")
        command.verification = true
        try command.validate()
        let record = NativeExecutionRecord(id: "verify", instanceID: "sbx-test", command: command)
        let restored = try JSONDecoder().decode(NativeExecutionRecord.self, from: JSON.data(record))
        expectTrue(NativeExecutionBrief(restored).verification == true)
        command.cwd = "."; expectThrows(try command.validate())
        let ordinary = try JSONDecoder().decode(NativeCommand.self, from: JSON.data(NativeCommand(["/bin/true"])))
        expectTrue(ordinary.verification == nil)
    }

    func taskPackages() throws {
        let source = root.appendingPathComponent("task source")
        try SafeFiles.secureDirectory(source)
        let agent = source.appendingPathComponent("agent")
        try SafeFiles.secureDirectory(agent)
        let files = [WorkspaceFile(path: "instruction.md", data: Data("task".utf8)),
                     WorkspaceFile(path: "setup.sh", data: Data("#!/bin/sh\necho prepared\n".utf8), executable: true),
                     WorkspaceFile(path: "fixtures/input.bin", data: Data(repeating: 31, count: WorkspaceArchive.chunkSize * 3 + 7)),
                     WorkspaceFile(path: "fixtures/tests/public.txt", data: Data("public fixture".utf8)),
                     WorkspaceFile(path: ".DS_Store", data: Data([1]))]
        let workspace = try ConfinedWorkspace(directory: agent)
        for file in files { try workspace.write(file) }
        let package = try ConfinedWorkspace(directory: source)
        try package.write(WorkspaceFile(path: "tests/test.sh", data: Data("private verifier\n".utf8)))
        try package.write(WorkspaceFile(path: "tests/hidden/expected.json", data: Data("private answers\n".utf8)))
        try package.write(WorkspaceFile(path: "operator_notes.txt", data: Data("not public\n".utf8)))
        let snapshot = root.appendingPathComponent("snapshot_with_tests.zip")
        try package.exportArchive(to: snapshot)
        expectTrue(try WorkspaceArchive.collect(snapshot).contains { $0.path == "tests/test.sh" })
        // Even unsafe/private descendants must not be inspected during import.
        expectEqual(mkfifo(source.appendingPathComponent("tests/pipe").path, 0o600), 0)
        let output = root.appendingPathComponent("prepared.zip")
        try TaskPackage.prepare(source, to: output)
        expectEqual(try WorkspaceArchive.collect(output), files.sorted { $0.path < $1.path })
        try FileManager.default.removeItem(at: source.appendingPathComponent("tests"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("tests").path, withDestinationPath: "fixtures")
        try TaskPackage.prepare(source, to: output)
        expectEqual(try WorkspaceArchive.collect(output), files.sorted { $0.path < $1.path })
        try FileManager.default.removeItem(at: source.appendingPathComponent("tests"))
        let original = try WorkspaceArchive.digest(output)
        let zip = root.appendingPathComponent("task.zip")
        try WorkspaceArchive.copy(output, to: zip)
        expectThrows(try TaskPackage.prepare(zip, to: output))
        expectEqual(try WorkspaceArchive.digest(output), original)

        try workspace.write(WorkspaceFile(path: "setup.sh", data: Data()))
        expectThrows(try TaskPackage.prepare(source, to: output))
        expectEqual(try WorkspaceArchive.digest(output), original)
        try FileManager.default.removeItem(at: agent.appendingPathComponent("setup.sh"))
        expectThrows(try TaskPackage.prepare(source, to: output))
        expectEqual(try WorkspaceArchive.digest(output), original)
        try workspace.write(files[1])
        try workspace.write(WorkspaceFile(path: "alias", data: Data(), linkTarget: "instruction.md"))
        expectThrows(try TaskPackage.prepare(source, to: output))
        expectEqual(try WorkspaceArchive.digest(output), original)
        try FileManager.default.removeItem(at: agent.appendingPathComponent("alias"))
        let link = root.appendingPathComponent("linked_task")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        expectThrows(try TaskPackage.prepare(link, to: output))
        let parent = root.appendingPathComponent("parent")
        try SafeFiles.secureDirectory(parent)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("task"), withIntermediateDirectories: false)
        expectThrows(try TaskPackage.prepare(parent, to: output))
        let fifo = agent.appendingPathComponent("pipe")
        expectEqual(mkfifo(fifo.path, 0o600), 0)
        expectThrows(try TaskPackage.prepare(source, to: output))
        expectEqual(try WorkspaceArchive.digest(output), original)
        try FileManager.default.removeItem(at: fifo)
        let saved = root.appendingPathComponent("saved_agent")
        try FileManager.default.moveItem(at: agent, to: saved)
        expectThrows(try TaskPackage.prepare(source, to: output))
        try FileManager.default.createSymbolicLink(at: agent, withDestinationURL: saved)
        expectThrows(try TaskPackage.prepare(source, to: output))
        expectEqual(try WorkspaceArchive.digest(output), original)
    }
}
