import Foundation
import SandboxCore

public struct VerificationSettings: Codable, Equatable {
    public var testPackageSHA256: String?
    public var enabled: Bool
    public var timeoutSeconds: Double
    public init(testPackageSHA256: String? = nil, enabled: Bool = false, timeoutSeconds: Double = 600) {
        self.testPackageSHA256 = testPackageSHA256; self.enabled = enabled; self.timeoutSeconds = timeoutSeconds
    }
    public func validate() throws {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, !enabled || testPackageSHA256 != nil else {
            throw SandboxError("automatic verification requires saved tests and a positive timeout")
        }
        if let hash = testPackageSHA256 {
            guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw SandboxError("invalid test package SHA-256")
            }
        }
    }
}

public struct AutomaticVerification: Codable {
    public var settings: VerificationSettings
    public var executionID = UUID().uuidString.lowercased()
    public var state = "waiting"
    public var error: String?
    public init(settings: VerificationSettings) { self.settings = settings }
}
