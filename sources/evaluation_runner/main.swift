import Foundation
import EvaluationCore
import SandboxCore

let help = """
evaluation-runner: experimental multi-turn core is available as EvaluationCore.
Trusted built-in acceptance only:
  evaluation-runner --version
  evaluation-runner --native-smoke --bin-dir PATH --output NEW_DIRECTORY
  evaluation-runner --managed-smoke --state-dir PATH --output NEW_DIRECTORY
Run tests/integration/app_sandbox_acceptance.py on the target Mac to collect real evidence.
No unsandboxed fallback.
"""
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--version"] { print(MetalSandboxVersion.current) }
else if arguments == ["--help"] { print(help) }
else if arguments.count == 5, arguments[0] == "--native-smoke", arguments[1] == "--bin-dir", arguments[3] == "--output" {
    do {
        exit(try runNativeSmoke(binDirectory: URL(fileURLWithPath: arguments[2]).standardizedFileURL,
                                output: URL(fileURLWithPath: arguments[4]).standardizedFileURL))
    } catch {
        FileHandle.standardError.write(Data("evaluation-runner: \(error)\n".utf8)); exit(1)
    }
} else if arguments.count == 5, arguments[0] == "--managed-smoke", arguments[1] == "--state-dir", arguments[3] == "--output" {
    do { exit(try runManagedSmoke(state: URL(fileURLWithPath: arguments[2]).standardizedFileURL,
                                 output: URL(fileURLWithPath: arguments[4]).standardizedFileURL)) }
    catch { FileHandle.standardError.write(Data("evaluation-runner: \(error)\n".utf8)); exit(1) }
} else { print(help); exit(2) }
