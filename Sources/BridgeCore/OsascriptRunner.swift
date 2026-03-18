import Foundation

public enum BridgeError: Error, LocalizedError {
    case scriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return msg
        }
    }
}

public func runJXA(_ script: String, timeout: TimeInterval = 30) async throws -> Any? {
    try await runOsascript(["-l", "JavaScript", "-e", script], timeout: timeout)
}

public func runAppleScript(_ script: String, timeout: TimeInterval = 30) async throws -> Any? {
    try await runOsascript(["-e", script], timeout: timeout)
}

public func runOsascript(_ arguments: [String], timeout: TimeInterval = 30) async throws -> Any? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stderr

    let exited = AsyncStream<Void> { cont in
        proc.terminationHandler = { _ in
            cont.yield()
            cont.finish()
        }
    }
    try proc.run()

    try await withThrowingTaskGroup(of: Void.self) { group in
        // Respond to cancellation by force-killing the process, since SIGTERM won't
        // interrupt a process blocked in a kernel TCC IPC wait.
        group.addTask {
            await withTaskCancellationHandler(
                operation: { for await _ in exited { break } },
                onCancel: { kill(proc.processIdentifier, SIGKILL) }
            )
        }
        group.addTask {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            kill(proc.processIdentifier, SIGKILL)
            throw BridgeError.scriptFailed("Script timed out after \(Int(timeout))s")
        }
        try await group.next()
        group.cancelAll()
    }

    guard proc.terminationStatus == 0 else {
        let errStr =
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw BridgeError.scriptFailed(errStr)
    }

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let output =
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !output.isEmpty else { return nil }
    return try JSONSerialization.jsonObject(
        with: Data(output.utf8), options: .fragmentsAllowed)
}
