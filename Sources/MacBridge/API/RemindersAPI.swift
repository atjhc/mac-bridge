import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.mac-bridge", category: "reminders")

class RemindersAPI {

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
            let errStr = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BridgeError.scriptFailed(errStr)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: Data(output.utf8))
    }

    // MARK: - Lists

    func getLists() async throws -> Any {
        let script = """
            const app = Application('Reminders');
            JSON.stringify(app.lists().map(l => ({
              id: l.id(),
              name: l.name(),
              color: l.color() || null,
              emblem: l.emblem() || null,
            })));
            """
        return try await runJXA(script) ?? []
    }

    // MARK: - Reminders

    func getReminders(listId: String?, completed: Bool?, limit: Int) async throws -> Any {
        let listFilter: String
        if let listId {
            listFilter = "const lists = [app.lists.byId(\(escapeJSString(listId)))];"
        } else {
            listFilter = "const lists = app.lists();"
        }

        let completedFilter: String
        if let completed {
            completedFilter = "if (r.completed() !== \(completed)) continue;"
        } else {
            completedFilter = ""
        }

        let script = """
            const app = Application('Reminders');
            function safeDate(fn) {
              try { const d = fn(); return d ? d.toISOString() : null; } catch { return null; }
            }
            \(listFilter)
            const results = [];
            for (const list of lists) {
              const reminders = list.reminders();
              for (const r of reminders) {
                \(completedFilter)
                results.push({
                  id: r.id(),
                  name: r.name(),
                  completed: r.completed(),
                  priority: r.priority(),
                  flagged: r.flagged(),
                  body: r.body() || null,
                  dueDate: safeDate(() => r.dueDate()),
                  remindMeDate: safeDate(() => r.remindMeDate()),
                  listId: list.id(),
                  listName: list.name(),
                });
                if (results.length >= \(limit)) break;
              }
              if (results.length >= \(limit)) break;
            }
            JSON.stringify(results);
            """
        return try await runJXA(script) ?? []
    }

    func getReminder(id: String) async throws -> Any? {
        let script = """
            const app = Application('Reminders');
            function safeDate(fn) {
              try { const d = fn(); return d ? d.toISOString() : null; } catch { return null; }
            }
            let found = null;
            const lists = app.lists();
            for (const list of lists) {
              const reminders = list.reminders.whose({id: \(escapeJSString(id))})();
              if (reminders.length > 0) {
                const r = reminders[0];
                found = {
                  id: r.id(),
                  name: r.name(),
                  completed: r.completed(),
                  priority: r.priority(),
                  flagged: r.flagged(),
                  body: r.body() || null,
                  dueDate: safeDate(() => r.dueDate()),
                  alldayDueDate: safeDate(() => r.alldayDueDate()),
                  remindMeDate: safeDate(() => r.remindMeDate()),
                  creationDate: safeDate(() => r.creationDate()),
                  modificationDate: safeDate(() => r.modificationDate()),
                  completionDate: safeDate(() => r.completionDate()),
                  listId: list.id(),
                  listName: list.name(),
                };
                break;
              }
            }
            JSON.stringify(found);
            """
        return try await runJXA(script)
    }

    // MARK: - Create

    func createReminder(name: String, notes: String?, listId: String?, dueDate: String?,
                        remindMeDate: String?, priority: Int?, flagged: Bool?) async throws -> Any {
        var props = ["name: \(escapeJSString(name))"]
        if let notes { props.append("body: \(escapeJSString(notes))") }
        if let priority { props.append("priority: \(priority)") }
        if let flagged { props.append("flagged: \(flagged)") }

        let dueDateLine: String
        if let dueDate {
            dueDateLine = "r.dueDate = new Date(\(escapeJSString(dueDate)));"
        } else {
            dueDateLine = ""
        }

        let remindMeDateLine: String
        if let remindMeDate {
            remindMeDateLine = "r.remindMeDate = new Date(\(escapeJSString(remindMeDate)));"
        } else {
            remindMeDateLine = ""
        }

        let listExpr: String
        if let listId {
            listExpr = "app.lists.byId(\(escapeJSString(listId)))"
        } else {
            listExpr = "app.defaultList()"
        }

        let script = """
            const app = Application('Reminders');
            const list = \(listExpr);
            const r = app.Reminder({\(props.joined(separator: ", "))});
            list.reminders.push(r);
            \(dueDateLine)
            \(remindMeDateLine)
            JSON.stringify({id: r.id(), name: r.name()});
            """
        return try await runJXA(script) ?? ["id": NSNull()]
    }

    // MARK: - Complete

    func completeReminders(ids: [String], completed: Bool) async throws -> Any {
        let idsJS = try String(data: JSONSerialization.data(withJSONObject: ids), encoding: .utf8) ?? "[]"
        let script = """
            const app = Application('Reminders');
            const ids = \(idsJS);
            const completed = \(completed);
            let updated = 0;
            const lists = app.lists();
            for (const id of ids) {
              for (const list of lists) {
                const matches = list.reminders.whose({id: id})();
                if (matches.length > 0) {
                  matches[0].completed = completed;
                  updated++;
                  break;
                }
              }
            }
            JSON.stringify({updated});
            """
        return try await runJXA(script) ?? ["updated": 0]
    }

    // MARK: - Delete

    func deleteReminders(ids: [String]) async throws -> Any {
        let idsJS = try String(data: JSONSerialization.data(withJSONObject: ids), encoding: .utf8) ?? "[]"
        let script = """
            const app = Application('Reminders');
            const ids = \(idsJS);
            let deleted = 0;
            const lists = app.lists();
            for (const id of ids) {
              for (const list of lists) {
                const matches = list.reminders.whose({id: id})();
                if (matches.length > 0) {
                  app.delete(matches[0]);
                  deleted++;
                  break;
                }
              }
            }
            JSON.stringify({deleted});
            """
        return try await runJXA(script) ?? ["deleted": 0]
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

