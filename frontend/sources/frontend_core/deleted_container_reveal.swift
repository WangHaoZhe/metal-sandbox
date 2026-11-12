import Foundation

/// Use only identities returned by successful deletion replies. The CLI owns
/// directory resolution and Finder integration; no paths are inferred here.
public struct DeletedContainerReveal {
    public let bundleIDs: [String]
    public init(replies: [CLIReply]) {
        bundleIDs = Array(Set(replies.flatMap { reply -> [String] in
            guard reply.ok, let instance = reply.instance, instance.state == "deleted",
                  !(reply.warnings ?? []).isEmpty else { return [] }
            return instance.ownedBundleIDs ?? []
        })).sorted()
    }
    public var arguments: [String] { ["reveal-containers"] + bundleIDs }
}
