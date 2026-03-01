import BridgeCore
import Vapor

func registerThingsRoutes(on routes: RoutesBuilder, api: ThingsAPI) {
    routes.get("help") { req -> Response in
        let markdown = """
            # Things 3 Bridge API

            HTTP bridge to Things 3.

            ## Response format

            All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

            Things 3 must be running for this bridge to work.

            ## Identifiers

            Things uses stable string IDs for todos, projects, areas, and lists. Built-in list IDs have fixed names like `TMTodayListSource`, `TMInboxListSource`, `TMUpcomingListSource`, etc.

            ## Status values

            Todo status is one of: `open`, `completed`, `cancelled`.

            ## Endpoints

            ### GET /things/lists
            List all built-in lists (Inbox, Today, Anytime, etc.) and areas. Returns `id` and `name`.

            ### GET /things/areas
            List user-defined areas. Returns `id` and `name`.

            ### GET /things/projects
            List all open projects.
            - `areaId` — filter by area

            Returns: `id`, `name`, `notes`, `area` ({id, name} or null)

            ### GET /things/todos
            List todos with optional filters. Only one of `listId`, `areaId`, `projectId` should be provided.
            - `listId` — filter by built-in list (e.g. `TMTodayListSource`)
            - `areaId` — filter by area
            - `projectId` — filter by project
            - `status` (default: "open") — filter by status, or "any" for all
            - `limit` (default: 50, max: 200)

            Returns: `id`, `name`, `notes`, `status`, `dueDate`, `activationDate`, `tags`, `project` ({id, name} or null), `area` ({id, name} or null)

            ### GET /things/todo
            Get a single todo with full details.
            - `id` (required)

            ### POST /things/todos
            Create a new todo.
            - `name` (required) — todo title
            - `notes` — additional notes
            - `dueDate` — ISO date string (YYYY-MM-DD)
            - `listId` — move to this list after creation
            - `projectId` — move to this project after creation

            Returns: `{"id": "..."}` with the new todo's identifier.

            ### POST /things/todos/status
            Set status on one or more todos.
            - `ids` (required) — array of todo ID strings
            - `status` (required) — "completed", "open", or "cancelled"

            Returns: `{"updated": N, "newRecurringInstances": [...]}`. When completing a repeating todo, Things creates a new open instance — these are returned in `newRecurringInstances`.

            ### POST /things/todos/delete
            Delete todos by ID.
            - `ids` (required) — array of todo ID strings

            ### GET /things/health
            Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

            ### GET /things/schema
            Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
            """
        return try responseJSON(["ok": true, "result": ["help": markdown]])
    }

    routes.get("health") { req -> Response in
        let health = checkAppHealth(bundleIdentifier: "com.culturedcode.ThingsMac")
        let result = buildAppHealthResult(
            "things-bridge", health: health,
            notInstalled: "Things 3 is not installed",
            notRunning: "Things 3 is not running")
        return try responseJSON(["ok": true, "result": result])
    }

    routes.get("schema") { req -> Response in
        let schema: [String: Any] = [
            "ok": true,
            "result": [
                "app": "things-bridge",
                "endpoints": [
                    [
                        "method": "GET",
                        "path": "/things/lists",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/things/areas",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/things/projects",
                        "params": [
                            ["name": "areaId", "from": "query", "type": "string"]
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/things/todos",
                        "params": [
                            ["name": "listId", "from": "query", "type": "string"],
                            ["name": "areaId", "from": "query", "type": "string"],
                            ["name": "projectId", "from": "query", "type": "string"],
                            [
                                "name": "status", "from": "query", "type": "string",
                                "default": "open",
                            ],
                            ["name": "limit", "from": "query", "type": "number", "default": 50],
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/things/todo",
                        "params": [
                            ["name": "id", "from": "query", "type": "string", "required": true]
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/things/todos",
                        "params": [
                            ["name": "name", "from": "body", "type": "string", "required": true],
                            ["name": "notes", "from": "body", "type": "string"],
                            ["name": "dueDate", "from": "body", "type": "string"],
                            ["name": "listId", "from": "body", "type": "string"],
                            ["name": "projectId", "from": "body", "type": "string"],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/things/todos/status",
                        "params": [
                            ["name": "ids", "from": "body", "type": "string[]", "required": true],
                            [
                                "name": "status", "from": "body", "type": "string",
                                "required": true,
                            ],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/things/todos/delete",
                        "params": [
                            ["name": "ids", "from": "body", "type": "string[]", "required": true]
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/things/help",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/things/health",
                        "params": [] as [[String: Any]],
                    ],
                ],
            ],
        ]
        return try responseJSON(schema)
    }

    routes.get("lists") { req async throws -> Response in
        let lists = try await api.getLists()
        return try responseJSON(["ok": true, "result": lists])
    }

    routes.get("areas") { req async throws -> Response in
        let areas = try await api.getAreas()
        return try responseJSON(["ok": true, "result": areas])
    }

    routes.get("projects") { req async throws -> Response in
        let areaId = req.query[String.self, at: "areaId"]
        let projects = try await api.getProjects(areaId: areaId)
        return try responseJSON(["ok": true, "result": projects])
    }

    routes.get("todos") { req async throws -> Response in
        let listId = req.query[String.self, at: "listId"]
        let areaId = req.query[String.self, at: "areaId"]
        let projectId = req.query[String.self, at: "projectId"]
        let status = req.query[String.self, at: "status"] ?? "open"
        let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)

        let todos = try await api.getTodos(
            listId: listId, areaId: areaId, projectId: projectId,
            status: status, limit: limit)
        return try responseJSON(["ok": true, "result": todos])
    }

    routes.get("todo") { req async throws -> Response in
        guard let id = req.query[String.self, at: "id"] else {
            throw Abort(.badRequest, reason: "'id' parameter is required")
        }
        let todo = try await api.getTodo(id: id)
        return try responseJSON(["ok": true, "result": todo as Any])
    }

    routes.post("todos") { req async throws -> Response in
        struct CreateTodoRequest: Content {
            let name: String
            let notes: String?
            let dueDate: String?
            let listId: String?
            let projectId: String?
        }

        let body = try req.content.decode(CreateTodoRequest.self)
        let result = try await api.createTodo(
            name: body.name, notes: body.notes, dueDate: body.dueDate,
            listId: body.listId, projectId: body.projectId)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("todos", "status") { req async throws -> Response in
        struct SetStatusRequest: Content {
            let ids: [String]
            let status: String
        }

        let body = try req.content.decode(SetStatusRequest.self)
        let result = try await api.setStatus(ids: body.ids, status: body.status)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("todos", "delete") { req async throws -> Response in
        struct DeleteTodosRequest: Content {
            let ids: [String]
        }

        let body = try req.content.decode(DeleteTodosRequest.self)
        let result = try await api.deleteTodos(ids: body.ids)
        return try responseJSON(["ok": true, "result": result])
    }
}
