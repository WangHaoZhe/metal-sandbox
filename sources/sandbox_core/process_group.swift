import Foundation
import Darwin

public struct ProcessCleanupDiagnostics: Codable {
    public var probes = 0
    public var probeErrors: [Int32] = []
    public var signalErrors: [Int32] = []
    public var finalProbeError: Int32?
    public init() {}
}

public enum ProcessGroup {
    public enum Observation: Equatable {
        case present, absent, unknown(Int32)
    }

    public static func observe(_ id: pid_t) -> Observation {
        guard id > 0 else { return .unknown(EINVAL) }
        let result = kill(-id, 0)
        let code = result < 0 ? errno : 0
        if result == 0 { return .present }
        return code == ESRCH ? .absent : .unknown(code)
    }

    public static func waitForAbsence(_ id: pid_t, seconds: Double) -> Bool {
        guard id > 0, seconds.isFinite, (0...3600).contains(seconds) else { return false }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, seconds) * 1e9)
        repeat {
            if observe(id) == .absent { return true }
            if DispatchTime.now().uptimeNanoseconds >= deadline { return false }
            usleep(10_000)
        } while true
    }

    public static func clean(_ id: pid_t) -> (gone: Bool, diagnostics: ProcessCleanupDiagnostics) {
        var diagnostics = ProcessCleanupDiagnostics()
        let started = DispatchTime.now().uptimeNanoseconds
        var terminated = false
        var escalated = false
        func signal(_ value: Int32) {
            var code: Int32
            repeat {
                let result = kill(-id, value)
                code = result < 0 ? errno : 0
            } while code == EINTR && DispatchTime.now().uptimeNanoseconds - started < 1_000_000_000
            if code != 0 && code != ESRCH && !diagnostics.signalErrors.contains(code) {
                diagnostics.signalErrors.append(code)
            }
        }
        guard id > 0 else { diagnostics.finalProbeError = EINVAL; return (false, diagnostics) }
        while true {
            diagnostics.probes += 1
            switch observe(id) {
            case .absent:
                diagnostics.finalProbeError = ESRCH
                return (true, diagnostics)
            case .present:
                diagnostics.finalProbeError = nil
            case .unknown(let code):
                diagnostics.finalProbeError = code
                if !diagnostics.probeErrors.contains(code) { diagnostics.probeErrors.append(code) }
            }
            if !terminated { signal(SIGTERM); terminated = true }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            if elapsed >= 0.25 && !escalated { signal(SIGKILL); escalated = true }
            if elapsed >= 1 { return (false, diagnostics) }
            usleep(10_000)
        }
    }
}
