import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.bridge", category: "shortcuts")

class ShortcutsAPI {

    private let shortcutsPath = "/usr/bin/shortcuts"

    // MARK: - CLI execution

    private func runCLI(_ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shortcutsPath)
        proc.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        // Close stdin so shortcuts that expect input don't block
        proc.standardInput = FileHandle.nullDevice

        try proc.run()

        let deadline = DispatchTime.now() + timeout
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            proc.waitUntilExit()
            done.signal()
        }

        if done.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            throw BridgeError.scriptFailed("Command timed out after \(Int(timeout))s")
        }

        guard proc.terminationStatus == 0 else {
            let errStr =
                String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BridgeError.scriptFailed(errStr.isEmpty ? "Command failed" : errStr)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    /// Parse "Name (UUID)" lines from `shortcuts list --show-identifiers`
    private func parseListOutput(_ output: String) -> [(name: String, id: String)] {
        guard !output.isEmpty else { return [] }
        return output.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(")"),
                let parenStart = trimmed.lastIndex(of: "(")
            else { return nil }
            let id = String(trimmed[trimmed.index(after: parenStart)..<trimmed.index(before: trimmed.endIndex)])
            let name = String(trimmed[..<parenStart]).trimmingCharacters(in: .whitespaces)
            return (name: name, id: id)
        }
    }

    // MARK: - Shortcuts

    func getShortcuts() throws -> [[String: Any]] {
        let output = try runCLI(["list", "--show-identifiers"])
        let folders = try getFolderMap()

        return parseListOutput(output).map { item in
            var entry: [String: Any] = [
                "id": item.id,
                "name": item.name,
            ]
            entry["folder"] = folders[item.id] ?? NSNull()
            return entry
        }
    }

    func getShortcut(id: String) throws -> [String: Any]? {
        let all = try getShortcuts()
        return all.first { ($0["id"] as? String) == id }
    }

    // MARK: - Folders

    func getFolders() throws -> [[String: Any]] {
        let output = try runCLI(["list", "--folders", "--show-identifiers"])
        return parseListOutput(output).map { item in
            var entry: [String: Any] = [
                "id": item.id,
                "name": item.name,
            ]
            // Count shortcuts in this folder
            if let folderContents = try? runCLI([
                "list", "--folder-name", item.name, "--show-identifiers",
            ]) {
                entry["shortcutCount"] = parseListOutput(folderContents).count
            }
            return entry
        }
    }

    /// Build a map of shortcut ID → folder name
    private func getFolderMap() throws -> [String: String] {
        let foldersOutput = try runCLI(["list", "--folders", "--show-identifiers"])
        let folders = parseListOutput(foldersOutput)
        var map: [String: String] = [:]
        for folder in folders {
            guard
                let contents = try? runCLI([
                    "list", "--folder-name", folder.name, "--show-identifiers",
                ])
            else { continue }
            for shortcut in parseListOutput(contents) {
                map[shortcut.id] = folder.name
            }
        }
        return map
    }

    // MARK: - Run

    func runShortcut(name: String?, id: String?, input: String?) throws -> [String: Any] {
        guard let identifier = name ?? id else {
            return ["ok": false, "error": "name or id is required"]
        }

        var args = ["run", identifier]

        var inputFile: URL?
        if let input {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try input.write(to: tempURL, atomically: true, encoding: .utf8)
            inputFile = tempURL
            args += ["-i", tempURL.path]
        }

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        args += ["-o", outputURL.path]

        defer {
            if let inputFile { try? FileManager.default.removeItem(at: inputFile) }
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            _ = try runCLI(args, timeout: 60)
        } catch {
            return ["name": identifier, "error": error.localizedDescription]
        }

        let outputStr =
            (try? String(contentsOf: outputURL, encoding: .utf8))?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? ""

        var result: [String: Any] = ["name": identifier]
        if outputStr.isEmpty {
            result["result"] = NSNull()
        } else {
            result["result"] = outputStr
        }
        return result
    }
}
