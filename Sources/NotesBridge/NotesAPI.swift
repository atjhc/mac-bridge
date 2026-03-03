import BridgeCore
import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.bridge", category: "notes")

class NotesAPI {

    private let bundleId = "com.apple.Notes"

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

    func getNotes(folder: String?, account: String?, search: String?, limit: Int) async throws
        -> Any
    {
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

    // MARK: - Helpers

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
