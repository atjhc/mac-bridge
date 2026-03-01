import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.bridge", category: "notes")

class NotesAPI {

    // MARK: - JXA execution

    private func runJXA(_ script: String, timeout: TimeInterval = 30) async throws -> Any? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-l", "JavaScript", "-e", script]

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
            group.addTask { for await _ in exited { break } }
            group.addTask {
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                proc.terminate()
                throw BridgeError.scriptFailed("Script timed out after \(Int(timeout))s")
            }
            try await group.next()
            group.cancelAll()
        }

        guard proc.terminationStatus == 0 else {
            let errStr =
                String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BridgeError.scriptFailed(errStr)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output =
            String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard !output.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: Data(output.utf8))
    }

    private func escapeJSString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
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
        return try await runJXA(script) ?? []
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
        return try await runJXA(script) ?? []
    }

    // MARK: - Notes

    func getNotes(folder: String?, account: String?, search: String?, limit: Int) async throws -> Any {
        let folderFilter = folder.map { escapeJSString($0) } ?? "null"
        let accountFilter = account.map { escapeJSString($0) } ?? "null"
        let searchFilter = search.map { escapeJSString($0.lowercased()) } ?? "null"
        let script = """
            const app = Application('Notes');
            function safeDate(fn) {
              try { const d = fn(); return d ? d.toISOString() : null; } catch { return null; }
            }
            const limit = \(limit);
            const searchTerm = \(searchFilter);
            let notes;
            const folderName = \(folderFilter);
            const accountName = \(accountFilter);
            if (folderName) {
              const folder = app.folders().find(f => f.name() === folderName);
              notes = folder ? folder.notes() : [];
            } else if (accountName) {
              const acct = app.accounts().find(a => a.name() === accountName);
              notes = acct ? acct.notes() : [];
            } else {
              notes = app.notes();
            }
            const results = [];
            for (let i = notes.length - 1; i >= 0 && results.length < limit; i--) {
              const note = notes[i];
              try {
                const plaintext = note.plaintext() || "";
                if (searchTerm && !plaintext.toLowerCase().includes(searchTerm)) continue;
                results.push({
                  id: note.id(),
                  name: note.name() || "",
                  preview: plaintext.substring(0, 200),
                  folder: (() => { try { return note.container().name(); } catch { return null; } })(),
                  creationDate: safeDate(() => note.creationDate()),
                  modificationDate: safeDate(() => note.modificationDate()),
                  passwordProtected: (() => { try { return note.passwordProtected(); } catch { return false; } })(),
                  shared: (() => { try { return note.shared(); } catch { return false; } })(),
                });
              } catch {}
            }
            JSON.stringify(results);
            """
        return try await runJXA(script) ?? []
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
        return try await runJXA(script)
    }

    // MARK: - Create

    func createNote(name: String, body: String, folder: String?, account: String?) async throws -> Any {
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
            const newNote = app.Note({
              name: \(escapeJSString(name)),
              body: \(escapeJSString(body))
            });
            app.notes.push(newNote);
            try {
              JSON.stringify({ id: newNote.id() });
            } catch {
              JSON.stringify({ id: null });
            }
            """
        return try await runJXA(script) ?? ["id": NSNull()]
    }

    // MARK: - Update

    func updateNote(id: String, name: String?, body: String?) async throws -> Any {
        let nameVal = name.map { escapeJSString($0) } ?? "null"
        let bodyVal = body.map { escapeJSString($0) } ?? "null"
        let script = """
            const app = Application('Notes');
            const targetId = \(escapeJSString(id));
            try {
              const note = app.notes.byId(targetId);
              if (note) {
                const newName = \(nameVal);
                if (newName) note.name = newName;
                const newBody = \(bodyVal);
                if (newBody) note.body = newBody;
                JSON.stringify({ updated: true });
              } else {
                JSON.stringify({ updated: false, error: "Note not found" });
              }
            } catch (e) {
              JSON.stringify({ updated: false, error: String(e) });
            }
            """
        return try await runJXA(script) ?? ["updated": false]
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
            } else {
              targetFolder = app.folders().find(f => f.name() === folderName);
            }
            if (!targetFolder) {
              JSON.stringify({ moved: 0, error: "Folder not found: " + folderName });
            } else {
              let moved = 0;
              for (const id of ids) {
                try {
                  const note = app.notes.byId(id);
                  if (note) {
                    app.move(note, { to: targetFolder });
                    moved++;
                  }
                } catch {}
              }
              JSON.stringify({ moved });
            }
            """
        return try await runJXA(script) ?? ["moved": 0]
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
                if (note) { note.delete(); deleted++; }
              } catch {}
            }
            JSON.stringify({ deleted });
            """
        return try await runJXA(script) ?? ["deleted": 0]
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
        return try await runJXA(script) ?? ["shown": false]
    }

    // MARK: - Search

    func searchNotes(query: String, limit: Int) async throws -> Any {
        let script = """
            const app = Application('Notes');
            function safeDate(fn) {
              try { const d = fn(); return d ? d.toISOString() : null; } catch { return null; }
            }
            const searchTerm = \(escapeJSString(query.lowercased()));
            const limit = \(limit);
            const notes = app.notes();
            const results = [];
            const maxScan = 500;
            let scanned = 0;
            for (let i = notes.length - 1; i >= 0 && results.length < limit && scanned < maxScan; i--) {
              const note = notes[i];
              scanned++;
              try {
                const plaintext = note.plaintext() || "";
                if (!plaintext.toLowerCase().includes(searchTerm)) continue;
                results.push({
                  id: note.id(),
                  name: note.name() || "",
                  preview: plaintext.substring(0, 200),
                  folder: (() => { try { return note.container().name(); } catch { return null; } })(),
                  modificationDate: safeDate(() => note.modificationDate()),
                });
              } catch {}
            }
            JSON.stringify(results);
            """
        return try await runJXA(script) ?? []
    }
}

