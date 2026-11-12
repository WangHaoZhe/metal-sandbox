import Foundation
import SandboxCore
import SandboxRuntime

extension RuntimeTests {
    func emptyDirectorySnapshots() throws {
        let source = root.appendingPathComponent("snapshot_source")
        let target = root.appendingPathComponent("snapshot_target")
        try SafeFiles.secureDirectory(source); try SafeFiles.secureDirectory(target)
        for path in ["empty", "nested/leaf", ".hidden_empty"] {
            try FileManager.default.createDirectory(at: source.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let original = try ConfinedWorkspace(directory: source)
        try original.write(WorkspaceFile(path: "src/keep.txt", data: Data("kept".utf8)))
        let archive = root.appendingPathComponent("empty_directories.zip")
        try original.exportArchive(to: archive)
        var directories = Set<String>()
        let summary = try WorkspaceArchive.read(archive, visitDirectory: { directories.insert($0) })
        expectEqual(directories, Set(["empty", "nested/leaf", ".hidden_empty"]))
        expectEqual(summary.files, 1)
        let copy = try ConfinedWorkspace(directory: target)
        try copy.importArchive(from: archive)
        for path in directories {
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: target.appendingPathComponent(path).path), [])
        }
        expectEqual(try copy.read("src/keep.txt").data, Data("kept".utf8))

        let digest = try WorkspaceArchive.digest(archive)
        expectThrows(try WorkspaceArchive.write(archive) { try $0.appendDirectory("../outside") })
        expectThrows(try WorkspaceArchive.write(archive) { writer in
            try writer.appendDirectory("same/empty")
            try writer.append(WorkspaceFile(path: "same", data: Data()))
        })
        expectThrows(try WorkspaceArchive.write(archive) { writer in
            try writer.append(WorkspaceFile(path: "same", data: Data()))
            try writer.appendDirectory("same/empty")
        })
        expectThrows(try WorkspaceArchive.write(archive) { writer in
            try writer.appendDirectory("same"); try writer.appendDirectory("same")
        })
        expectEqual(try WorkspaceArchive.digest(archive), digest)

        let outside = root.appendingPathComponent("outside")
        try SafeFiles.secureDirectory(outside)
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("redirect"), withDestinationURL: outside)
        try WorkspaceArchive.write(archive) { try $0.appendDirectory("redirect/empty") }
        expectThrows(try copy.importArchive(from: archive))
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
}
