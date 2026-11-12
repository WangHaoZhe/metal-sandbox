import Foundation
import Metal
import Darwin
import IOKit

public struct HostInfo: Codable {
    public var modelIdentifier: String
    public var productName: String?
    public var hostname: String
    public var osVersion: String
    public var osBuild: String
    public var architecture: String
    public var cpu: String
    public var logicalCPUs: Int
    public var memoryBytes: UInt64
    public var metalDevice: String?
    public var metalRegistryID: UInt64?
    public var thermalState: String
    public var utilization: HostUtilization
    public var observedAt: Date

    private static let hardwareProductName: String? = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
              let name = String(data: data.prefix { $0 != 0 }, encoding: .utf8), !name.isEmpty else { return nil }
        return name
    }()

    public static func capture() -> HostInfo {
        let info = ProcessInfo.processInfo
        let device = MTLCreateSystemDefaultDevice()
        let thermal: String
        switch info.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return HostInfo(modelIdentifier: sysctlString("hw.model"), productName: hardwareProductName,
                        hostname: info.hostName, osVersion: info.operatingSystemVersionString,
                        osBuild: sysctlString("kern.osversion"), architecture: arch,
                        cpu: sysctlString("machdep.cpu.brand_string"), logicalCPUs: info.processorCount,
                        memoryBytes: info.physicalMemory, metalDevice: device?.name,
                        metalRegistryID: device?.registryID, thermalState: thermal,
                        utilization: HostUtilizationSampler.shared.capture(deviceID: device?.registryID), observedAt: Date())
    }
}

public struct HostUtilization: Codable {
    public var cpuPercent: Double?
    public var gpuPercent: Double?
    public var cpuError: String?
    public var gpuError: String?
    public var memoryUsedBytes: UInt64?
    public var memoryTotalBytes: UInt64?
    public var memoryError: String?
    public var storageUsedBytes: UInt64?
    public var storageTotalBytes: UInt64?
    public var storageError: String?
    public var sampledAt: Date
}

private final class HostUtilizationSampler {
    static let shared = HostUtilizationSampler()
    private let lock = NSLock()
    private var previousCPU: [UInt32]?
    private var lastSample: HostUtilization?
    private var lastUptime: TimeInterval = -1

    func capture(deviceID: UInt64?) -> HostUtilization {
        lock.lock(); defer { lock.unlock() }
        let uptime = ProcessInfo.processInfo.systemUptime
        if let lastSample, uptime - lastUptime < 1 { return lastSample }
        var sample = HostUtilization(sampledAt: Date())
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        sampleCPU(into: &sample, host: host)
        sampleGPU(into: &sample, deviceID: deviceID)
        sampleMemory(into: &sample, host: host)
        sampleStorage(into: &sample)
        lastUptime = uptime; lastSample = sample
        return sample
    }

    private func sampleCPU(into sample: inout HostUtilization, host: host_t) {
        var cpu = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            previousCPU = nil
            sample.cpuError = "Cannot read CPU statistics: Mach error \(result)"; return
        }
        let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
        defer { self.previousCPU = ticks }
        guard let previousCPU else { sample.cpuError = "Waiting for the next CPU sample"; return }
        let deltas = zip(ticks, previousCPU).map { Double($0 &- $1) }
        let total = deltas.reduce(0, +)
        if total > 0 { sample.cpuPercent = (total - deltas[Int(CPU_STATE_IDLE)]) / total * 100 }
        else { sample.cpuError = "CPU statistics have not updated" }
    }

    private func sampleGPU(into sample: inout HostUtilization, deviceID: UInt64?) {
        guard let deviceID else { sample.gpuError = "No Metal device found"; return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(deviceID))
        guard service != 0 else { sample.gpuError = "Cannot read IOKit statistics for this Metal device"; return }
        defer { IOObjectRelease(service) }
        let statistics = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
        if let value = (statistics?["Device Utilization %"] as? NSNumber)?.doubleValue,
           value.isFinite, (0...100).contains(value) {
            sample.gpuPercent = value
        } else { sample.gpuError = "This Metal device does not provide valid GPU utilization statistics" }
    }

    /// Matches Activity Monitor's "Memory Used": app memory plus wired and compressed pages, excluding file cache.
    private func sampleMemory(into sample: inout HostUtilization, host: host_t) {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            sample.memoryError = "Cannot read memory statistics: Mach error \(result)"; return
        }
        let pageSize = UInt64(getpagesize())
        let appPages = UInt64(info.internal_page_count) &- min(UInt64(info.purgeable_count), UInt64(info.internal_page_count))
        let total = ProcessInfo.processInfo.physicalMemory
        let used = (appPages + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * pageSize
        sample.memoryUsedBytes = min(used, total)
        sample.memoryTotalBytes = total
    }

    /// Reads volume capacity from file-system metadata (statfs); it never walks directories.
    private func sampleStorage(into sample: inout HostUtilization) {
        let volume = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        do {
            let values = try volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity,
                  total > 0, available >= 0, available <= total else {
                sample.storageError = "This volume does not provide valid capacity statistics"; return
            }
            sample.storageUsedBytes = UInt64(total - available)
            sample.storageTotalBytes = UInt64(total)
        } catch {
            sample.storageError = "Cannot read storage capacity: \(error.localizedDescription)"
        }
    }
}

private func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: bytes)
}
