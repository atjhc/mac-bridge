import BridgeCore
import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.mac-bridge", category: "notes")

class NotesAPI {

    private let bundleId = "com.apple.Notes"

    private func launchAndRunJXA(_ script: String, timeout: TimeInterval = 30) async throws
        -> Any?
    {
        ensureAppRunning(bundleIdentifier: bundleId)
        return try await BridgeCore.runJXA(script, timeout: timeout)
    }

    // MARK: - Health

    func healthCheck() -> [String: Any] {
        let installed = isAppInstalled(bundleIdentifier: bundleId)
        let running = isAppRunning(bundleIdentifier: bundleId)
        return buildHealthResult(
            app: "notes-bridge",
            status: installed ? "ok" : "error",
            details: [
                "appInstalled": installed,
                "appRunning": running,
            ]
        )
    }

    // MARK: - Accounts & Folders

    func getAccounts() async throws -> Any {
        let script = """
            const app = Application('Notes');
            JSON.stringify(app.accounts().map(acct => ({
              id: acct.id(),
              name: acct.name(),
            })));
            """
        return try await launchAndRunJXA(script) ?? []
    }

    func getFolders(account: String?) async throws -> Any {
        let accountFilter = account.map { escapeJSString($0) } ?? "null"
        let script = """
            const app = Application('Notes');
            const targetAccount = \(accountFilter);
            let folders;
            if (targetAccount) {
              const acct = app.accounts().find(a => a.name() === targetAccount);
              folders = acct ? acct.folders() : [];
            } else {
              folders = app.folders();
            }
            JSON.stringify(folders.map(f => ({
              id: f.id(),
              name: f.name(),
              shared: (() => { try { return f.shared(); } catch { return false; } })(),
            })));
            """
        return try await launchAndRunJXA(script) ?? []
    }

    // MARK: - Notes

    func getNotes(folder: String?, account: String?, search: String?, limit: Int, offset: Int)
        async throws -> Any
    {
        let folderFilter = folder.map { escapeJSString($0) } ?? "null"
        let accountFilter = account.map { escapeJSString($0) } ?? "null"
        let searchFilter = search.map { escapeJSString($0.lowercased()) } ?? "null"
        // Batch-fetch all properties in single IPC calls to avoid per-note round trips
        let script = """
            const app = Application('Notes');
            const limit = \(limit);
            const offset = \(offset);
            const searchTerm = \(searchFilter);
            const folderName = \(folderFilter);
            const accountName = \(accountFilter);
            let noteRef;
            if (folderName) {
              const folder = app.folders().find(f => f.name() === folderName);
              noteRef = folder ? folder.notes : null;
            } else if (accountName) {
              const acct = app.accounts().find(a => a.name() === accountName);
              noteRef = acct ? acct.notes : null;
            } else {
              noteRef = app.notes;
            }
            if (!noteRef) {
              JSON.stringify({ notes: [], total: 0, matched: 0 });
            } else {
              const ids = noteRef.id();
              const names = noteRef.name();
              const modDates = noteRef.modificationDate();
              const creDates = noteRef.creationDate();
              const folders = noteRef.container.name();
              const total = ids.length;
              const results = [];
              let matched = 0;
              for (let i = ids.length - 1; i >= 0 && results.length < limit; i--) {
                const name = names[i] || "";
                if (searchTerm && !name.toLowerCase().includes(searchTerm)) continue;
                matched++;
                if (matched <= offset) continue;
                results.push({
                  id: ids[i],
                  name: name,
                  preview: name,
                  folder: folders[i] || null,
                  creationDate: creDates[i] ? creDates[i].toISOString() : null,
                  modificationDate: modDates[i] ? modDates[i].toISOString() : null,
                });
              }
              JSON.stringify({ notes: results, total: total, matched: matched });
            }
            """
        return try await launchAndRunJXA(script, timeout: 30) ?? []
    }

    func getNote(id: String) async throws -> Any? {
        let script = """
            const app = Application('Notes');
            function safeDate(fn) {
              try { const d = fn(); return d ? d.toISOString() : null; } catch { return null; }
            }
            const targetId = \(escapeJSString(id));
            let found = null;
            try {
              const note = app.notes.byId(targetId);
              if (note) {
                found = {
                  id: note.id(),
                  name: note.name() || "",
                  body: note.body() || "",
                  plaintext: note.plaintext() || "",
                  folder: (() => { try { return note.container().name(); } catch { return null; } })(),
                  creationDate: safeDate(() => note.creationDate()),
                  modificationDate: safeDate(() => note.modificationDate()),
                  passwordProtected: (() => { try { return note.passwordProtected(); } catch { return false; } })(),
                  shared: (() => { try { return note.shared(); } catch { return false; } })(),
                };
              }
            } catch {}
            JSON.stringify(found);
            """
        return try await launchAndRunJXA(script)
    }

    // MARK: - Create Folder

    func createFolder(name: String, account: String?) async throws -> Any {
        let accountFilter = account.map { escapeJSString($0) } ?? "null"
        let script = """
            const app = Application('Notes');
            const folderName = \(escapeJSString(name));
            const accountName = \(accountFilter);
            let targetAccount = null;
            if (accountName) {
              targetAccount = app.accounts().find(a => a.name() === accountName);
            }
            if (!targetAccount) {
              targetAccount = app.defaultAccount();
            }
            const folder = app.Folder({ name: folderName });
            targetAccount.folders.push(folder);
            delay(0.5);
            const found = targetAccount.folders().find(f => f.name() === folderName);
            JSON.stringify({ id: found ? found.id() : null, name: folderName });
            """
        return try await launchAndRunJXA(script) ?? ["id": NSNull()]
    }

    // MARK: - Create Note

    func createNote(name: String, body: String, folder: String?, account: String?) async throws
        -> Any
    {
        let folderFilter = folder.map { escapeJSString($0) } ?? "null"
        let accountFilter = account.map { escapeJSString($0) } ?? "null"
        let script = """
            const app = Application('Notes');
            let targetFolder = null;
            const folderName = \(folderFilter);
            if (folderName) {
              targetFolder = app.folders().find(f => f.name() === folderName);
            }
            if (!targetFolder) {
              const accountName = \(accountFilter);
              if (accountName) {
                const acct = app.accounts().find(a => a.name() === accountName);
                targetFolder = acct ? acct.defaultFolder() : null;
              }
            }
            if (!targetFolder) {
              targetFolder = app.defaultAccount().defaultFolder();
            }
            const noteName = \(escapeJSString(name));
            const note = app.Note({ name: noteName, body: \(escapeJSString(htmlBody(body))) });
            let created = false;
            try {
              targetFolder.notes.push(note);
              created = true;
            } catch (e) {
              const msg = String(e);
              if (msg.includes('Smart Folder')) {
                JSON.stringify({ id: null, error: 'Cannot create notes in Smart Folder \"' + targetFolder.name() + '\". Create in a regular folder instead.' });
              } else {
                JSON.stringify({ id: null, error: msg });
              }
            }
            if (created) {
              delay(1);
              const notes = targetFolder.notes();
              let foundId = null;
              for (let i = notes.length - 1; i >= 0; i--) {
                try {
                  if (notes[i].name() === noteName) { foundId = notes[i].id(); break; }
                } catch {}
              }
              JSON.stringify({ id: foundId });
            }
            """
        return try await launchAndRunJXA(script) ?? ["id": NSNull()]
    }

    // MARK: - Update

    func updateNote(id: String, name: String?, body: String?) async throws -> Any {
        let nameVal = name.map { escapeJSString($0) } ?? "null"
        let bodyVal = body.map { escapeJSString(htmlBody($0)) } ?? "null"
        // Set body BEFORE name — Notes derives title from body's first line,
        // so setting name last ensures it sticks.
        let script = """
            const app = Application('Notes');
            const targetId = \(escapeJSString(id));
            try {
              const note = app.notes.byId(targetId);
              note.id();
              const newBody = \(bodyVal);
              if (newBody) note.body = newBody;
              const newName = \(nameVal);
              if (newName) note.name = newName;
              JSON.stringify({ updated: true });
            } catch (e) {
              JSON.stringify({ updated: false, error: String(e) });
            }
            """
        return try await launchAndRunJXA(script) ?? ["updated": false]
    }

    // MARK: - Move

    func moveNotes(ids: [String], folder: String, account: String?) async throws -> Any {
        let idsJS =
            try String(data: JSONSerialization.data(withJSONObject: ids), encoding: .utf8) ?? "[]"
        let accountFilter = account.map { escapeJSString($0) } ?? "null"
        let script = """
            const app = Application('Notes');
            const ids = \(idsJS);
            const folderName = \(escapeJSString(folder));
            const accountName = \(accountFilter);
            let targetFolder = null;
            if (accountName) {
              const acct = app.accounts().find(a => a.name() === accountName);
              if (acct) targetFolder = acct.folders().find(f => f.name() === folderName);
            }
            if (!targetFolder) {
              targetFolder = app.folders().find(f => f.name() === folderName);
            }
            if (!targetFolder) {
              JSON.stringify({ moved: 0, error: "Folder not found: " + folderName });
            } else {
              let moved = 0;
              for (const id of ids) {
                try {
                  const note = app.notes.byId(id);
                  note.id();
                  app.move(note, { to: targetFolder }); moved++;
                } catch {}
              }
              JSON.stringify({ moved });
            }
            """
        return try await launchAndRunJXA(script) ?? ["moved": 0]
    }

    // MARK: - Delete

    func deleteNotes(ids: [String]) async throws -> Any {
        let idsJS =
            try String(data: JSONSerialization.data(withJSONObject: ids), encoding: .utf8) ?? "[]"
        let script = """
            const app = Application('Notes');
            const ids = \(idsJS);
            let deleted = 0;
            for (const id of ids) {
              try {
                const note = app.notes.byId(id);
                note.id();
                note.delete(); deleted++;
              } catch {}
            }
            JSON.stringify({ deleted });
            """
        return try await launchAndRunJXA(script) ?? ["deleted": 0]
    }

    // MARK: - Show

    func showNote(id: String) async throws -> Any {
        let script = """
            const app = Application('Notes');
            const targetId = \(escapeJSString(id));
            try {
              const note = app.notes.byId(targetId);
              if (note) {
                app.show(note);
                JSON.stringify({ shown: true });
              } else {
                JSON.stringify({ shown: false, error: "Note not found" });
              }
            } catch (e) {
              JSON.stringify({ shown: false, error: String(e) });
            }
            """
        return try await launchAndRunJXA(script) ?? ["shown": false]
    }

    // MARK: - Search

    func searchNotes(query: String, limit: Int) async throws -> Any {
        let script = """
            const app = Application('Notes');
            const searchTerm = \(escapeJSString(query.lowercased()));
            const limit = \(limit);
            // Batch-fetch all properties in single IPC calls
            const ids = app.notes.id();
            const names = app.notes.name();
            const modDates = app.notes.modificationDate();
            const folders = app.notes.container.name();
            const results = [];
            for (let i = ids.length - 1; i >= 0 && results.length < limit; i--) {
              const name = names[i] || "";
              if (!name.toLowerCase().includes(searchTerm)) continue;
              results.push({
                id: ids[i],
                name: name,
                preview: name,
                folder: folders[i] || null,
                modificationDate: modDates[i] ? modDates[i].toISOString() : null,
              });
            }
            JSON.stringify(results);
            """
        return try await launchAndRunJXA(script, timeout: 30) ?? []
    }

    // MARK: - Shortcuts-based features (AppIntents via Shortcuts Events)

    /// Preflight: verify Shortcuts can run (Mac unlocked, automation allowed).
    private func ensureShortcutsReady() async throws {
        do {
            // "Wait" is a built-in shortcut-like no-op; any fast shortcut works.
            // The real test is whether Shortcuts Events responds at all.
            _ = try await BridgeCore.runOsascript(
                ["-e", "tell application \"Shortcuts Events\" to name of it"], timeout: 5)
        } catch let error as BridgeError {
            let msg = error.localizedDescription
            if msg.contains("unlocked") || msg.contains("locked") {
                throw BridgeError.scriptFailed(
                    "Shortcuts requires your Mac to be unlocked. Unlock the screen and retry.")
            }
            if msg.contains("not allowed") || msg.contains("denied") {
                throw BridgeError.scriptFailed(
                    "Shortcuts automation is blocked. Grant access in System Settings > Privacy & Security > Automation."
                )
            }
            throw BridgeError.scriptFailed("Shortcuts unavailable: \(msg)")
        }
    }

    @discardableResult
    private func runNotesShortcut(_ name: String, input: [String: Any]) async throws -> Any? {
        let jsonData = try JSONSerialization.data(withJSONObject: input)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"
        let escaped = jsonStr
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script =
            "tell application \"Shortcuts Events\" to run shortcut \"\(name)\" with input \"\(escaped)\""
        do {
            // runAppleScript parses stdout as JSON, but Shortcuts returns "missing value"
            // which isn't valid JSON. Use runOsascript directly and handle the output ourselves.
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            let exited = AsyncStream<Void> { cont in
                proc.terminationHandler = { _ in cont.yield(); cont.finish() }
            }
            try proc.run()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { for await _ in exited { break } }
                group.addTask {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    kill(proc.processIdentifier, SIGKILL)
                    throw BridgeError.scriptFailed(
                        "Shortcut '\(name)' timed out. Ensure your Mac is unlocked and Notes has granted Shortcuts access."
                    )
                }
                try await group.next()
                group.cancelAll()
            }

            guard proc.terminationStatus == 0 else {
                let errStr =
                    String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if errStr.contains("unlocked") || errStr.contains("locked") {
                    throw BridgeError.scriptFailed(
                        "Shortcuts requires your Mac to be unlocked. Unlock the screen and retry.")
                }
                if errStr.contains("find shortcut") || errStr.contains("Couldn't find") {
                    throw BridgeError.scriptFailed(
                        "Shortcut '\(name)' not installed. Run scripts/install-shortcuts.sh")
                }
                throw BridgeError.scriptFailed("Shortcut '\(name)' failed: \(errStr)")
            }

            return nil
        }
    }

    /// Resolve a note ID to its name (needed for Shortcuts entity resolution).
    private func resolveNoteName(id: String) async throws -> String? {
        let script = """
            const app = Application('Notes');
            try {
              const note = app.notes.byId(\(escapeJSString(id)));
              JSON.stringify(note.name());
            } catch {
              JSON.stringify(null);
            }
            """
        guard let result = try await launchAndRunJXA(script) else { return nil }
        return result as? String
    }

    /// Get the note name from either `id` or `noteName` parameter.
    private func noteNameFromParams(id: String?, noteName: String?) async throws -> String {
        if let noteName { return noteName }
        guard let id else {
            throw BridgeError.scriptFailed("Either 'id' or 'noteName' is required")
        }
        guard let name = try await resolveNoteName(id: id) else {
            throw BridgeError.scriptFailed("Note not found: \(id)")
        }
        return name
    }

    func createNoteFromMarkdown(name: String, markdown: String, folder: String?) async throws
        -> Any
    {
        var input: [String: Any] = ["name": name, "content": markdown]
        if let folder { input["folder"] = folder }
        try await runNotesShortcut("MacBridge - Notes Create Markdown", input: input)
        return ["created": true]
    }

    func appendMarkdown(id: String?, noteName: String?, markdown: String) async throws -> Any {
        let name = try await noteNameFromParams(id: id, noteName: noteName)
        try await runNotesShortcut(
            "MacBridge - Notes Append Markdown", input: ["noteName": name, "markdown": markdown])
        return ["appended": true]
    }

    func addChecklistItem(id: String?, noteName: String?, text: String) async throws -> Any {
        let name = try await noteNameFromParams(id: id, noteName: noteName)
        try await runNotesShortcut(
            "MacBridge - Notes Add Checklist Item", input: ["noteName": name, "text": text])
        return ["added": true]
    }

    func addTags(id: String, tags: [String]) async throws -> Any {
        let hashTags = tags.map { $0.hasPrefix("#") ? $0 : "#\($0)" }
        let tagDiv = hashTags.joined(separator: " ")
        let script = """
            const app = Application('Notes');
            try {
              const note = app.notes.byId(\(escapeJSString(id)));
              note.id();
              const body = note.body();
              note.body = body + '<div>\(tagDiv)</div>';
              JSON.stringify({ added: true });
            } catch (e) {
              JSON.stringify({ added: false, error: String(e) });
            }
            """
        return try await launchAndRunJXA(script) ?? ["added": false]
    }

    func removeTags(id: String, tags: [String]) async throws -> Any {
        let script = """
            const app = Application('Notes');
            try {
              const note = app.notes.byId(\(escapeJSString(id)));
              note.id();
              let body = note.body();
              const tagsToRemove = \(escapeJSString(tags.joined(separator: ",")));
              for (const tag of tagsToRemove.split(',')) {
                const t = tag.trim();
                const hashTag = t.startsWith('#') ? t : '#' + t;
                body = body.replace(new RegExp(hashTag + '\\\\b', 'g'), '');
              }
              note.body = body;
              JSON.stringify({ removed: true });
            } catch (e) {
              JSON.stringify({ removed: false, error: String(e) });
            }
            """
        return try await launchAndRunJXA(script) ?? ["removed": false]
    }

    func addTable(id: String?, noteName: String?, csv: String, tableName: String?) async throws
        -> Any
    {
        let name = try await noteNameFromParams(id: id, noteName: noteName)
        var input: [String: Any] = ["noteName": name, "csv": csv]
        if let tableName { input["name"] = tableName }
        try await runNotesShortcut("MacBridge - Notes Add Table", input: input)
        return ["added": true]
    }

    func pinNote(id: String?, noteName: String?) async throws -> Any {
        let name = try await noteNameFromParams(id: id, noteName: noteName)
        try await runNotesShortcut("MacBridge - Notes Pin", input: ["noteName": name])
        return ["pinned": true]
    }

    func unpinNote(id: String?, noteName: String?) async throws -> Any {
        let name = try await noteNameFromParams(id: id, noteName: noteName)
        try await runNotesShortcut("MacBridge - Notes Unpin", input: ["noteName": name])
        return ["unpinned": true]
    }

    // MARK: - Helpers

    /// Notes.app body is HTML — convert plain-text newlines to `<br>` so they're preserved.
    /// Passes through content that already contains HTML tags.
    private func htmlBody(_ text: String) -> String {
        if text.contains("<br") || text.contains("<p") || text.contains("<div") {
            return text
        }
        return text.replacingOccurrences(of: "\n", with: "<br>")
    }

    private func escapeJSString(_ s: String) -> String {
        let escaped =
            s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}
