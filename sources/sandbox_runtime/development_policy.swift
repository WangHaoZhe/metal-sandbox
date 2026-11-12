import Foundation
import Darwin
import SandboxCore

/// Public Apple entitlements, restricted to this identity's existing writable
/// workspace/tmp and the operator's read-only development tools. Outbound
/// network is an explicit per-instance operator option, disabled by default.
public enum DevelopmentPolicy {
    public static var operatorHome: URL {
        URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir), isDirectory: true)
    }
    public static var toolsRoot: URL {
        operatorHome.appendingPathComponent("Library/Application Support/MetalSandbox/development_tools")
    }
    public static var toolDirectories: [URL] {
        [toolsRoot.appendingPathComponent("cmake"), toolsRoot.appendingPathComponent("ninja")]
    }
    public static func hostEntitlements(identifier: String, toolchain: InstalledClang, networkClient: Bool = false, sharedWorkspace: SharedWorkspace? = nil) -> [String: Any] {
        let base = operatorHome.appendingPathComponent("Library/Containers/\(identifier)/Data/Library/Application Support/MetalSandbox")
        let paths = [base.appendingPathComponent("workspace"), base.appendingPathComponent("tmp"), base.appendingPathComponent("home")] + toolDirectories
            + [toolchain.metalToolchainDirectory].compactMap { $0.map { URL(fileURLWithPath: $0) } }
        var entitlements: [String: Any] = [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.files.user-selected.executable": true,
            "com.apple.security.files.bookmarks.app-scope": true,
            // Apple's read-only path exception also permits process-exec there.
            // workspace/tmp are already writable through the container policy.
            "com.apple.security.temporary-exception.files.absolute-path.read-only": paths.map { $0.path + "/" },
        ]
        if networkClient { entitlements["com.apple.security.network.client"] = true }
        if let sharedWorkspace {
            entitlements["com.apple.security.temporary-exception.files.absolute-path.read-write"] = [sharedWorkspace.workspace.path + "/", sharedWorkspace.home.path + "/"]
        }
        return entitlements
    }
}

/// Hold public security scopes for our OWN directories before starting children.
/// Creating a bookmark alone is not enough: the active read-write extension is
/// required by Apple's executable-writing entitlement. Fail closed on denial.
public final class DevelopmentScopes {
    private var urls: [URL] = []
    public init(directories: [URL]) throws {
        do {
            for directory in directories {
                let data = try directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale, url.standardizedFileURL.path == directory.standardizedFileURL.path,
                      url.startAccessingSecurityScopedResource() else { throw SandboxError("cannot activate owned development directory scope") }
                urls.append(url)
            }
        } catch { urls.forEach { $0.stopAccessingSecurityScopedResource() }; urls = []; throw error }
    }
    deinit { urls.forEach { $0.stopAccessingSecurityScopedResource() } }
}
