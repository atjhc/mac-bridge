import AppKit

public struct AppHealthStatus {
    public let installed: Bool
    public let running: Bool

    public var isHealthy: Bool { installed && running }
}

public func checkAppHealth(bundleIdentifier: String) -> AppHealthStatus {
    let installed =
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    let running =
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    return AppHealthStatus(installed: installed, running: running)
}
