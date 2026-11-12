// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetalSandbox",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "metal-sandboxd", targets: ["SandboxDaemon"]),
        .executable(name: "sandboxctl", targets: ["SandboxCLI"]),
        .executable(name: "metal-runner", targets: ["MetalRunner"]),
        .executable(name: "sandbox-selftest", targets: ["SandboxSelfTests"]),
        .executable(name: "sandbox-host", targets: ["SandboxHost"]),
        .executable(name: "sandbox-shell", targets: ["SandboxShell"]),
        .executable(name: "sandbox-probe", targets: ["SandboxProbe"]),
        .executable(name: "evaluation-runner", targets: ["EvaluationRunner"]),
    ],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "SandboxCore", path: "sources/sandbox_core", linkerSettings: [.linkedFramework("Metal"), .linkedFramework("IOKit")]),
        .executableTarget(name: "SandboxDaemon", dependencies: ["SandboxCore", "SandboxManagement"], path: "sources/sandbox_daemon"),
        .executableTarget(name: "SandboxCLI", dependencies: ["SandboxCore", "SandboxRuntime"], path: "sources/sandbox_cli"),
        .executableTarget(name: "MetalRunner", dependencies: ["SandboxCore"], path: "sources/metal_runner"),
        .target(name: "SandboxRuntime", dependencies: ["SandboxCore", .product(name: "ZIPFoundation", package: "ZIPFoundation")], path: "sources/sandbox_runtime", resources: [.copy("resources/default_task_policy.json"), .copy("resources/third_party_notices.md")], linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreServices")]),
        .target(name: "SandboxManagement", dependencies: ["SandboxRuntime"], path: "sources/sandbox_management"),
        .target(name: "EvaluationCore", dependencies: ["SandboxCore", "SandboxRuntime"], path: "sources/evaluation_core"),
        .executableTarget(name: "SandboxShell", dependencies: ["SandboxCore", "SandboxRuntime"], path: "sources/sandbox_shell"),
        .executableTarget(name: "SandboxHost", dependencies: ["SandboxCore", "SandboxRuntime"], path: "sources/sandbox_host"),
        .executableTarget(name: "SandboxProbe", dependencies: ["SandboxCore"], path: "sources/sandbox_probe"),
        .executableTarget(name: "EvaluationRunner", dependencies: ["EvaluationCore"], path: "sources/evaluation_runner"),
        // CLT-only Macs do not necessarily ship XCTest. These tests use a tiny
        // dependency-free executable harness instead of requiring full Xcode.
        .executableTarget(name: "SandboxSelfTests", dependencies: ["SandboxCore", "SandboxRuntime", "SandboxManagement", "EvaluationCore"], path: "tests/sandbox_core_tests"),
    ],
    swiftLanguageModes: [.v5]
)
