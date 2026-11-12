import Foundation
import FrontendCore

extension SelfTests {
    static func environmentTests() throws {
        let values = ["KEY": "quotes ' \" $HOME $(literal)\n", "EMPTY": ""]
        try require(try EnvironmentDocument.values(EnvironmentDocument.rows(values)) == values, "literal environment roundtrip")
        try require(try EnvironmentDocument.values([EnvironmentRow()]).isEmpty, "empty row ignored")
        for rows in [[EnvironmentRow(key: "HOME", value: "bad")], [EnvironmentRow(key: "A", value: "1"), EnvironmentRow(key: "A", value: "2")], [EnvironmentRow(value: "missing key")], [EnvironmentRow(key: "KEY", value: "\0")]] {
            var rejected = false
            do { _ = try EnvironmentDocument.values(rows) } catch { rejected = true }
            try require(rejected, "invalid or duplicate environment accepted")
        }
        let reply = try JSONDecoder().decode(CLIReply.self, from: Data(#"{"ok":true,"environmentKeys":["KEY"]}"#.utf8))
        try require(reply.environment == nil && reply.environmentKeys == ["KEY"], "default response must not reveal values")
        print("PASS environment editor: literal values, empty rows, reserved/duplicate keys, NUL rejection and value-free default reply")
    }
}
