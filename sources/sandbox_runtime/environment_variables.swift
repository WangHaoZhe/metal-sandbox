import Foundation
import SandboxCore

public enum EnvironmentVariables {
    public static func validate(_ values: [String: String]) throws {
        for (key, value) in values {
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
                throw SandboxError("environment variable names must match [A-Za-z_][A-Za-z0-9_]*")
            }
            guard !["HOME", "TMPDIR", "WORKSPACE"].contains(key), !key.hasPrefix("METAL_SANDBOX_") else {
                throw SandboxError("reserved runtime environment variable: \(key)")
            }
            guard !value.contains("\0") else { throw SandboxError("environment values cannot contain NUL") }
        }
    }
    public static func decode(_ data: Data) throws -> [String: String] {
        guard let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw SandboxError("environment must be a JSON object with string values")
        }
        try validate(values); return values
    }
}
