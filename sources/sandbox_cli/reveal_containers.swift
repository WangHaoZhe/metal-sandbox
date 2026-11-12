import AppKit
import Foundation
import SandboxCore
import SandboxRuntime

struct ContainerRevealReply: Encodable {
    let ok = true
    let paths: [String]
    let missing: [String]
    let finderRequested: Bool
    let warnings: [String]?
}

func revealWorkspaceLocation(_ path: String, preview: Bool) throws -> ContainerRevealReply {
    guard path.hasPrefix(NSHomeDirectory() + "/Library/Containers/local.metal-sandbox.instance-") else {
        throw SandboxError("unexpected workspace location")
    }
    // Finder selects the entry; it never launches a candidate executable.
    if !preview { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    return ContainerRevealReply(paths: [path], missing: [], finderRequested: !preview, warnings: nil)
}

/// A trusted local CLI action, not candidate execution or container cleanup.
/// Inspect only the exact named directory entries; never enumerate their Data.
func revealContainers(_ identifiers: [String], preview: Bool) throws -> ContainerRevealReply {
    let (urls, missing) = try ContainerShell.locations(identifiers)
    let requested = !preview && !urls.isEmpty
    if requested { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    let warnings = missing.isEmpty ? nil : [urls.isEmpty
        ? "All selected, confirmed container directories no longer exist."
        : "Skipped \(missing.count) confirmed container directories that no longer exist."]
    return ContainerRevealReply(paths: urls.map(\.path), missing: missing,
                                finderRequested: requested, warnings: warnings)
}
