import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.bridge", category: "shortcuts")

class ShortcutsAPI {

    // MARK: - JXA execution

    private func runJXA(_ script: String) throws -> Any? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-l", "JavaScript", "-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errStr = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BridgeError.scriptFailed(errStr)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: Data(output.utf8))
    }

    // MARK: - Shortcuts

    func getShortcuts() throws -> Any {
        let script = """
            const app = Application('Shortcuts');
            JSON.stringify(app.shortcuts().map(s => ({
              id: s.id(),
              name: s.name(),
              subtitle: s.subtitle() || null,
              folder: (() => { try { const f = s.folder(); return f ? f.name() : null; } catch { return null; } })(),
              acceptsInput: s.acceptsInput(),
              actionCount: s.actionCount(),
            })));
            """
        return try runJXA(script) ?? []
    }

    func getShortcut(id: String) throws -> Any? {
        let script = """
            const app = Application('Shortcuts');
            const shortcuts = app.shortcuts().filter(s => s.id() === \(escapeJSString(id)));
            if (shortcuts.length === 0) { JSON.stringify(null); }
            else {
              const s = shortcuts[0];
              JSON.stringify({
                id: s.id(),
                name: s.name(),
                subtitle: s.subtitle() || null,
                folder: (() => { try { const f = s.folder(); return f ? f.name() : null; } catch { return null; } })(),
                acceptsInput: s.acceptsInput(),
                actionCount: s.actionCount(),
              });
            }
            """
        return try runJXA(script)
    }

    // MARK: - Folders

    func getFolders() throws -> Any {
        let script = """
            const app = Application('Shortcuts');
            JSON.stringify(app.folders().map(f => ({
              id: f.id(),
              name: f.name(),
              shortcutCount: f.shortcuts().length,
            })));
            """
        return try runJXA(script) ?? []
    }

    // MARK: - Run

    func runShortcut(name: String?, id: String?, input: String?) throws -> Any {
        guard name != nil || id != nil else {
            return ["ok": false, "error": "name or id is required"]
        }

        // Use Shortcuts Events to run in background
        let findExpr: String
        if let name {
            findExpr = """
                const matches = app.shortcuts().filter(s => s.name() === \(escapeJSString(name)));
                if (matches.length === 0) throw new Error('Shortcut not found: ' + \(escapeJSString(name)));
                const shortcut = matches[0];
                """
        } else {
            findExpr = """
                const matches = app.shortcuts().filter(s => s.id() === \(escapeJSString(id!)));
                if (matches.length === 0) throw new Error('Shortcut not found: ' + \(escapeJSString(id!)));
                const shortcut = matches[0];
                """
        }

        let inputArg: String
        if let input {
            inputArg = ", {input: \(escapeJSString(input))}"
        } else {
            inputArg = ""
        }

        let script = """
            const app = Application('Shortcuts Events');
            \(findExpr)
            const result = app.run(shortcut\(inputArg));
            JSON.stringify({name: shortcut.name(), result: result || null});
            """
        return try runJXA(script) ?? ["result": NSNull()]
    }

    // MARK: - Helpers

    private func escapeJSString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

enum BridgeError: Error, LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return msg
        }
    }
}
