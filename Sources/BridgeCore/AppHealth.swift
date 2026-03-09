import AppKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.mac-bridge", category: "app-health")

@discardableResult
public func ensureAppRunning(bundleIdentifier: String, timeout: TimeInterval = 10) -> Bool {
    if isAppRunning(bundleIdentifier: bundleIdentifier) { return true }

    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else { return false }

    log.notice("Launching \(bundleIdentifier)")
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false

    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in sem.signal() }
    _ = sem.wait(timeout: .now() + 3)

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if isAppRunning(bundleIdentifier: bundleIdentifier) {
            log.notice("\(bundleIdentifier) is now running")
            return true
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    log.warning("\(bundleIdentifier) failed to launch within \(Int(timeout))s")
    return false
}

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
