import AppKit
import BridgeCore
import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.mac-bridge", category: "things")

class ThingsAPI {

    private let bundleId = "com.culturedcode.ThingsMac"

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
            app: "things-bridge",
            status: installed ? "ok" : "error",
            details: [
                "appInstalled": installed,
                "appRunning": running,
            ]
        )
    }

    // MARK: - Lists & Areas

    func getLists() async throws -> Any {
        let script = """
            const app = Application('Things3');
            JSON.stringify(app.lists().map(l => ({ id: l.id(), name: l.name() })));
            """
        return try await launchAndRunJXA(script) ?? []
    }

    func getAreas() async throws -> Any {
        let script = """
            const app = Application('Things3');
            JSON.stringify(app.areas().map(a => ({ id: a.id(), name: a.name() })));
            """
        return try await launchAndRunJXA(script) ?? []
    }

    // MARK: - Projects

    func getProjects(areaId: String?) async throws -> Any {
        let areaFilter = areaId.map { escapeJSString($0) } ?? "null"
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
        return try await launchAndRunJXA(script) ?? []
    }

    // MARK: - Todos

    func getTodos(
        listId: String?, areaId: String?, projectId: String?, status: String, limit: Int,
        offset: Int
    ) async throws -> Any {
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
            const offset = \(offset);
            let todos;
            \(todoSource)
            const results = [];
            let matched = 0;
            for (const todo of todos) {
              if (targetStatus !== "any" && todo.status() !== targetStatus) continue;
              matched++;
              if (matched <= offset) continue;
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
        return try await launchAndRunJXA(script) ?? []
    }

    func getTodo(id: String) async throws -> Any? {
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
        return try await launchAndRunJXA(script)
    }

    // MARK: - Create (AppleScript — JXA `make` fails with -2710)

    func createTodo(
        name: String, notes: String?, dueDate: String?, listId: String?, projectId: String?
    ) async throws -> Any {
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
        ensureAppRunning(bundleIdentifier: bundleId)
        return try await runAppleScript(script) ?? ["id": NSNull()]
    }

    // MARK: - Update

    func updateTodo(id: String, name: String?, notes: String?, dueDate: String?, tags: String?)
        async throws -> Any
    {
        var setLines: [String] = []
        if let name { setLines.append("todo.name = \(escapeJSString(name));") }
        if let notes { setLines.append("todo.notes = \(escapeJSString(notes));") }
        if let tags { setLines.append("todo.tagNames = \(escapeJSString(tags));") }
        if let dueDate {
            setLines.append("todo.dueDate = new Date(\(escapeJSString(dueDate)));")
        }

        let script = """
            const app = Application('Things3');
            try {
              const todo = app.toDos.byId(\(escapeJSString(id)));
              \(setLines.joined(separator: "\n      "))
              JSON.stringify({ updated: true });
            } catch (e) {
              JSON.stringify({ updated: false, error: String(e) });
            }
            """
        return try await launchAndRunJXA(script) ?? ["updated": false]
    }

    // MARK: - Create Project

    func createProject(name: String, notes: String?, areaId: String?) async throws -> Any {
        var props = ["name: \(escapeASString(name))"]
        if let notes { props.append("notes: \(escapeASString(notes))") }

        var moveCmd = ""
        if let areaId {
            moveCmd = "move newProj to area id \(escapeASString(areaId))"
        }

        let script = """
            tell application "Things3"
              set newProj to make new project with properties {\(props.joined(separator: ", "))}
              \(moveCmd)
              set theId to id of newProj
              return "{" & quote & "id" & quote & ":" & quote & theId & quote & "}"
            end tell
            """
        ensureAppRunning(bundleIdentifier: bundleId)
        return try await runAppleScript(script) ?? ["id": NSNull()]
    }

    // MARK: - Create Heading

    func createHeading(projectId: String, title: String) async throws -> Any {
        // Things headings are only creatable via URL scheme
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let urlStr = "things:///update-project?id=\(projectId)&prepend-heading=\(encoded)"
        guard let url = URL(string: urlStr) else {
            return ["created": false, "error": "Invalid URL"]
        }
        ensureAppRunning(bundleIdentifier: bundleId)
        NSWorkspace.shared.open(url)
        return ["created": true]
    }

    // MARK: - Status

    func setStatus(ids: [String], status: String) async throws -> Any {
        let idsJS =
            try String(data: JSONSerialization.data(withJSONObject: ids), encoding: .utf8) ?? "[]"
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
        return try await launchAndRunJXA(script) ?? ["updated": 0]
    }

    // MARK: - Delete

    func deleteTodos(ids: [String]) async throws -> Any {
        let idsJS =
            try String(data: JSONSerialization.data(withJSONObject: ids), encoding: .utf8) ?? "[]"
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
        return try await launchAndRunJXA(script) ?? ["deleted": 0]
    }

    // MARK: - Helpers

    private func escapeJSString(_ s: String) -> String {
        let escaped =
            s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func escapeASString(_ s: String) -> String {
        let escaped =
            s
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
