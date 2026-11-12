import Foundation
import SandboxCore
import SandboxRuntime

extension RuntimeTests {
    func environmentVariables() throws {
        let values = ["API_KEY": "literal '$HOME' $(not executed)\n", "EMPTY": "", "PATH": "/usr/bin:/bin"]
        expectEqual(try EnvironmentVariables.decode(JSON.data(values)), values)
        for key in ["", "1KEY", "KEY=VALUE", "bad-name", "HOME", "TMPDIR", "WORKSPACE", "METAL_SANDBOX_JOB_ID"] {
            expectThrows(try EnvironmentVariables.validate([key: "test"]))
        }
        expectThrows(try EnvironmentVariables.validate(["KEY": "a\0b"]))
        expectThrows(try EnvironmentVariables.decode(Data(#"{"KEY":12}"#.utf8)))
        let reply = NativeControlReply(requestID: "test")
        expectFalse(String(decoding: try JSON.data(reply), as: UTF8.self).contains("literal"))
        let command = NativeCommand(["/bin/true"])
        expectFalse(String(decoding: try JSON.data(command), as: UTF8.self).contains("environment"))
    }
}
