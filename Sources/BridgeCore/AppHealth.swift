import AppKit
import Foundation

public func buildHealthResult(
    app: String,
    status: String,
    details: [String: Any]
) -> [String: Any] {
    var result: [String: Any] = [
        "status": status,
        "app": app,
    ]
    for (key, value) in details {
        result[key] = value
    }
    return result
}

public func isAppInstalled(bundleIdentifier: String) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
}

public func isAppRunning(bundleIdentifier: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
}
