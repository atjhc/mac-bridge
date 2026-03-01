import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.bridge", category: "things")

class ThingsAPI {

    // MARK: - JXA / AppleScript execution

    private func runJXA(_ script: String, timeout: TimeInterval = 30) async throws -> Any? {
        try await runOsascript(["-l", "JavaScript", "-e", script], timeout: timeout)
    }

    private func runAppleScript(_ script: String, timeout: TimeInterval = 30) async throws -> Any? {
        try await runOsascript(["-e", script], timeout: timeout)
    }

    private func runOsascript(_ arguments: [String], timeout: TimeInterval) async throws -> Any? {
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

    // MARK: - Lists & Areas

    func getLists() async throws -> Any {
        let script = """
            const app = Application('Things3');
            JSON.stringify(app.lists().map(l => ({ id: l.id(), name: l.name() })));
            """
        return try await runJXA(script) ?? []
    }

    func getAreas() async throws -> Any {
        let script = """
            const app = Application('Things3');
            JSON.stringify(app.areas().map(a => ({ id: a.id(), name: a.name() })));
            """
        return try await runJXA(script) ?? []
    }

    // MARK: - Projects

    func getProjects(areaId: String?) async throws -> Any {
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
        return try await runJXA(script) ?? []
    }

    // MARK: - Todos

    func getTodos(listId: String?, areaId: String?, projectId: String?, status: String, limit: Int) async throws -> Any {
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
        return try await runJXA(script) ?? []
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
        return try await runJXA(script)
    }

    // MARK: - Create (AppleScript — JXA `make` fails with -2710)

    func createTodo(name: String, notes: String?, dueDate: String?, listId: String?, projectId: String?) async throws -> Any {
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
        return try await runAppleScript(script) ?? ["id": NSNull()]
    }

    // MARK: - Status

    func setStatus(ids: [String], status: String) async throws -> Any {
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
        return try await runJXA(script) ?? ["updated": 0]
    }

    // MARK: - Delete

    func deleteTodos(ids: [String]) async throws -> Any {
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

