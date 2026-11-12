import Foundation
import Darwin
import SandboxCore

final class CoreTests {
    var root: URL!
    func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-unit-\(UUID().uuidString.lowercased())")
        try SafeFiles.secureDirectory(root)
    }
    func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }
    func testReleaseMetadata() throws {
        expectEqual(MetalSandboxVersion.current, "1.0.0")
        expectEqual(MetalSandboxVersion.bundleShortVersion, "1.0.0")
        expectEqual(MetalSandboxVersion.bundleBuild, "8")
    }
    func testHostMemoryAndStorageUtilization() throws {
        let host = HostInfo.capture()
        let memoryUsed = try unwrap(host.utilization.memoryUsedBytes), memoryTotal = try unwrap(host.utilization.memoryTotalBytes)
        expectEqual(memoryTotal, host.memoryBytes)
        expectGreater(memoryUsed, 0)
        expectLessOrEqual(memoryUsed, memoryTotal)
        let storageUsed = try unwrap(host.utilization.storageUsedBytes), storageTotal = try unwrap(host.utilization.storageTotalBytes)
        expectGreater(storageUsed, 0)
        expectLessOrEqual(storageUsed, storageTotal)
    }
    func testRegularReaderRejectsSymlinkAndOversize() throws {
        let file = root.appendingPathComponent("file")
        try SafeFiles.writeData(Data(repeating: 1, count: 100), to: file)
        expectThrows(try SafeFiles.readRegular(file, limit: 99))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        expectThrows(try SafeFiles.readRegular(link, limit: 100))
    }

    func testLeaseRejectsSecondOwner() throws {
        let path = root.appendingPathComponent("lease")
        let lease = try FileLease(path)
        expectThrows(try FileLease(path))
        withExtendedLifetime(lease) {}
    }

}
