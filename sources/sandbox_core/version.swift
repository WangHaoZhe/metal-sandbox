/// Single source of release identity. Packaging reads these literals; it does
/// not generate or modify source files during a build.
public enum MetalSandboxVersion {
    public static let current = "1.0.0"
    public static let bundleBuild = "8"
    public static var bundleShortVersion: String { String(current.split(separator: "-")[0]) }
}
