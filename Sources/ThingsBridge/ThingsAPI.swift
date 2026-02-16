import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.bridge", category: "things")

class ThingsAPI {

    // MARK: - JXA / AppleScript execution

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

    private func runAppleScript(_ script: String) throws -> Any? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]

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

    // MARK: - Lists & Areas

    func getLists() throws -> Any {
        let script = """
            const app = Application('Things3');
            JSON.stringify(app.lists().map(l => ({ id: l.id(), name: l.name() })));
            """
        return try runJXA(script) ?? []
    }

    func getAreas() throws -> Any {
        let script = """
            const app = Application('Things3');
            JSON.stringify(app.areas().map(a => ({ id: a.id(), name: a.name() })));
            """
        return try runJXA(script) ?? []
    }

    // MARK: - Projects

    func getProjects(areaId: String?) throws -> Any {
        let areaFilter = areaId.map { "JSON.parse(\(escapeJSString($0)))" } ?? "null"
        let script = """
            const app = Application('Things3');
            const targetAreaId = \(areaFilter);
            const projects = app.projects().filter(pr => {
              if (pr.status() !== "open") return false;
              if (!targetAreaId) return true;
              try { return pr.area() && pr.area().id() === targetAreaId; } catch { return false; }
            });
            JSON.stringify(projects.map(pr => ({
              id: pr.id(),
              name: pr.name(),
              notes: pr.notes() || null,
              area: (() => { try { const a = pr.area(); return a ? { id: a.id(), name: a.name() } : null; } catch { return null; } })(),
            })));
            """
        return try runJXA(script) ?? []
    }

    // MARK: - Todos

    func getTodos(listId: String?, areaId: String?, projectId: String?, status: String, limit: Int) throws -> Any {
        let todoSource: String
        if let listId {
            todoSource = "todos = app.lists.byId(\(escapeJSString(listId))).toDos();"
        } else if let areaId {
            todoSource = "todos = app.areas.byId(\(escapeJSString(areaId))).toDos();"
        } else if let projectId {
            todoSource = "todos = app.projects.byId(\(escapeJSString(projectId))).toDos();"
        } else {
            todoSource = "todos = app.toDos();"
        }

        let script = """
            const app = Application('Things3');
            function safeDate(fn) {
              try { const d = fn(); return d ? d.toISOString() : null; } catch { return null; }
            }
            const targetStatus = \(escapeJSString(status));
            const limit = \(limit);
            let todos;
            \(todoSource)
            const results = [];
            for (const todo of todos) {
              if (targetStatus !== "any" && todo.status() !== targetStatus) continue;
              const project = (() => { try { const pr = todo.project(); return pr ? { id: pr.id(), name: pr.name() } : null; } catch { return null; } })();
              const area = (() => { try { const a = todo.area(); return a ? { id: a.id(), name: a.name() } : null; } catch { return null; } })();
              results.push({
                id: todo.id(),
                name: todo.name(),
                notes: todo.notes() || null,
                status: todo.status(),
                dueDate: safeDate(() => todo.dueDate()),
                activationDate: safeDate(() => todo.activationDate()),
                tags: todo.tagNames() || null,
                project,
                area,
              });
              if (results.length >= limit) break;
            }
            JSON.stringify(results);
            """
        return try runJXA(script) ?? []
    }

    func getTodo(id: String) throws -> Any? {
        let script = """
            const app = Application('Things3');
            function safeDate(fn) {
              try { const d = fn(); return d ? d.toISOString() : null; } catch { return null; }
            }
            const todo = app.toDos.byId(\(escapeJSString(id)));
            if (!todo) {
              JSON.stringify(null);
            } else {
              const project = (() => { try { const pr = todo.project(); return pr ? { id: pr.id(), name: pr.name() } : null; } catch { return null; } })();
              const area = (() => { try { const a = todo.area(); return a ? { id: a.id(), name: a.name() } : null; } catch { return null; } })();
              JSON.stringify({
                id: todo.id(),
                name: todo.name(),
                notes: todo.notes() || null,
                status: todo.status(),
                dueDate: safeDate(() => todo.dueDate()),
                activationDate: safeDate(() => todo.activationDate()),
                tags: todo.tagNames() || null,
                project,
                area,
              });
            }
            """
        return try runJXA(script)
    }

    // MARK: - Create (AppleScript — JXA `make` fails with -2710)

    func createTodo(name: String, notes: String?, dueDate: String?, listId: String?, projectId: String?) throws -> Any {
        var props = ["name: \(escapeASString(name))"]
        if let notes {
            props.append("notes: \(escapeASString(notes))")
        }
        if let dueDate {
            props.append("due date: date \(escapeASString(isoToASDate(dueDate)))")
        }

        var moveCmd = ""
        if let listId, listId != "TMInboxListSource" {
            moveCmd = "move newToDo to list id \(escapeASString(listId))"
        }
        if let projectId {
            moveCmd = "move newToDo to project id \(escapeASString(projectId))"
        }

        let script = """
            tell application "Things3"
              set newToDo to make new to do with properties {\(props.joined(separator: ", "))}
              \(moveCmd)
              set theId to id of newToDo
              return "{" & quote & "id" & quote & ":" & quote & theId & quote & "}"
            end tell
            """
        return try runAppleScript(script) ?? ["id": NSNull()]
    }

    // MARK: - Status

    func setStatus(ids: [String], status: String) throws -> Any {
        let idsJS = try String(data: JSONSerialization.data(withJSONObject: ids), encoding: .utf8) ?? "[]"
        let script = """
            const app = Application('Things3');
            function safeDate(fn) {
              try { const d = fn(); return d ? d.toISOString() : null; } catch { return null; }
            }
            const ids = \(idsJS);
            const newStatus = \(escapeJSString(status));
            let updated = 0;
            const completedNames = [];
            for (const id of ids) {
              try {
                const todo = app.toDos.byId(id);
                if (todo) {
                  if (newStatus === "completed") completedNames.push(todo.name());
                  todo.status = newStatus;
                  updated++;
                }
              } catch {}
            }
            const newRecurringInstances = [];
            if (completedNames.length > 0) {
              const openTodos = app.toDos().filter(t => {
                try { return t.status() === "open"; } catch { return false; }
              });
              for (const todo of openTodos) {
                try {
                  if (completedNames.includes(todo.name())) {
                    const project = (() => { try { const pr = todo.project(); return pr ? { id: pr.id(), name: pr.name() } : null; } catch { return null; } })();
                    newRecurringInstances.push({
                      id: todo.id(),
                      name: todo.name(),
                      dueDate: safeDate(() => todo.dueDate()),
                      project,
                    });
                  }
                } catch {}
              }
            }
            JSON.stringify({ updated, newRecurringInstances });
            """
        return try runJXA(script) ?? ["updated": 0]
    }

    // MARK: - Delete

    func deleteTodos(ids: [String]) throws -> Any {
        let idsJS = try String(data: JSONSerialization.data(withJSONObject: ids), encoding: .utf8) ?? "[]"
        let script = """
            const app = Application('Things3');
            const ids = \(idsJS);
            let deleted = 0;
            for (const id of ids) {
              try {
                const todo = app.toDos.byId(id);
                if (todo) { todo.delete(); deleted++; }
              } catch {}
            }
            JSON.stringify({ deleted });
            """
        return try runJXA(script) ?? ["deleted": 0]
    }

    // MARK: - Helpers

    private func escapeJSString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func escapeASString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Convert ISO date "2026-03-15" to AppleScript date format "03/15/2026"
    private func isoToASDate(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3 else { return iso }
        return "\(parts[1])/\(parts[2])/\(parts[0])"
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
