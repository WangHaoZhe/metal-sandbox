import Foundation

public struct SandboxError: Error, CustomStringConvertible, LocalizedError {
    public enum Code: String, Codable {
        case instanceInactive = "instance_inactive"
        case clusterReservationExpired = "cluster_reservation_expired"
        case clusterTaskUnknown = "cluster_task_unknown"
        case instanceCapacityUnavailable = "instance_capacity_unavailable"
    }
    public let description: String
    public let code: Code?
    public var errorDescription: String? { description }
    public init(_ message: String, code: Code? = nil) { description = message; self.code = code }
}

public enum ExecutionTiming {
    public static let resultGraceSeconds: Double = 10
}

public enum JSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
    public static func data<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        try encoder(pretty: pretty).encode(value)
    }
    public static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try data(value, pretty: true), as: UTF8.self)
    }
}

public enum MonotonicDeadline {
    /// Saturate only at the clock's representable limit, never at a policy cap.
    public static func after(_ seconds: Double, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> UInt64 {
        guard seconds > 0 else { return now }
        let nanoseconds = seconds * 1e9
        guard nanoseconds.isFinite, nanoseconds < Double(UInt64.max - now) else { return UInt64.max }
        return now + UInt64(nanoseconds)
    }
}

public struct ProcessOutcome: Codable {
    public enum Reason: String, Codable { case exited, signalled, timedOut, cancelled, outputLimit, launchFailed }
    public var processID: Int32
    public var reason: Reason
    public var exitCode: Int32?
    public var terminationSignal: Int32?
    public var elapsedSeconds: Double
    public var cleanupSeconds: Double
    public var processGroupGone = true
    public var cleanupDiagnostics: ProcessCleanupDiagnostics?
    public var launchError: String?

    public init(processID: Int32, reason: Reason, exitCode: Int32? = nil, terminationSignal: Int32? = nil,
                elapsedSeconds: Double, cleanupSeconds: Double, processGroupGone: Bool = true, launchError: String? = nil) {
        self.processID = processID; self.reason = reason; self.exitCode = exitCode; self.terminationSignal = terminationSignal
        self.elapsedSeconds = elapsedSeconds; self.cleanupSeconds = cleanupSeconds; self.processGroupGone = processGroupGone
        self.launchError = launchError
    }

    /// A cleaned failure may resume trusted development, not certify GPU drain.
    public var requiresInspection: Bool {
        !processGroupGone
    }
}

public struct MetalDiagnostics: Codable {
    public var device: String
    public var registryID: UInt64
    public var elementCount: Int
    public var iterations: Int
    public var warmup: Int
    public var threadgroupSize: Int
    public var gpuSeconds: [Double]
    public var submissionToCompletionSeconds: [Double]
    public var measurementScope: String
    public init(device: String, registryID: UInt64, count: Int, iterations: Int, warmup: Int,
                threadgroupSize: Int, gpuSeconds: [Double], submissionSeconds: [Double]) {
        self.device = device; self.registryID = registryID; self.elementCount = count
        self.iterations = iterations; self.warmup = warmup; self.threadgroupSize = threadgroupSize
        self.gpuSeconds = gpuSeconds; self.submissionToCompletionSeconds = submissionSeconds
        self.measurementScope = "candidate-reported command-buffer diagnostics; NOT graphics FPS"
    }
}
