import Foundation
import Darwin
import SandboxCore

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--version"] { print(MetalSandboxVersion.current) }
    else { try runNativeDaemon(arguments) }
} catch {
    FileHandle.standardError.write(Data("metal-sandboxd: \(error)\n".utf8))
    exit(1)
}
