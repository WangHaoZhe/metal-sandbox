// swift-tools-version: 6.0
import PackageDescription

// Deliberately independent: the UI communicates with the backend ONLY via CLI.
let package = Package(
    name: "MetalSandboxFrontend",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "metal-sandbox-ui", targets: ["FrontendApp"]),
        .executable(name: "frontend-selftest", targets: ["FrontendTests"]),
    ],
    targets: [
        .target(name: "FrontendCore", path: "sources/frontend_core"),
        .executableTarget(name: "FrontendApp", dependencies: ["FrontendCore"], path: "sources/frontend_app"),
        .executableTarget(name: "FrontendTests", dependencies: ["FrontendCore"], path: "tests"),
        .testTarget(name: "FrontendAppTests", dependencies: ["FrontendApp", "FrontendCore"], path: "app_tests"),
    ],
    swiftLanguageModes: [.v5]
)
