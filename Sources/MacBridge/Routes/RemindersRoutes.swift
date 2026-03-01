import BridgeCore
import Vapor

func registerRemindersRoutes(on routes: RoutesBuilder, api: RemindersAPI) {
    routes.get("help") { req -> Response in
        let markdown = """
            # Reminders Bridge API

            HTTP bridge to macOS Reminders.

            ## Response format

            All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

            Reminders must be running for this bridge to work.

            ## Endpoints

            ### GET /reminders/lists
            List all reminder lists. Returns `id`, `name`, `color`, `emblem`.

            ### GET /reminders/reminders
            List reminders with optional filters.
            - `listId` — filter by list
            - `completed` — filter by completion status (true/false)
            - `limit` (default: 50, max: 200)

            Returns: `id`, `name`, `completed`, `priority`, `flagged`, `body`, `dueDate`, `remindMeDate`, `listId`, `listName`

            ### GET /reminders/reminder
            Get a single reminder with full details.
            - `id` (required)

            ### POST /reminders/reminders
            Create a new reminder.
            - `name` (required) — reminder title
            - `notes` — body text
            - `listId` — target list (uses default list if omitted)
            - `dueDate` — ISO date string
            - `remindMeDate` — ISO date-time string
            - `priority` — integer (0=none, 1=high, 5=medium, 9=low)
            - `flagged` — boolean

            ### POST /reminders/reminders/complete
            Mark reminders as complete or incomplete.
            - `ids` (required) — array of reminder ID strings
            - `completed` (required) — boolean

            ### POST /reminders/reminders/delete
            Delete reminders by ID.
            - `ids` (required) — array of reminder ID strings

            ### GET /reminders/health
            Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

            ### GET /reminders/schema
            Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
            """
        return try responseJSON(["ok": true, "result": ["help": markdown]])
    }

    routes.get("health") { req -> Response in
        let health = checkAppHealth(bundleIdentifier: "com.apple.reminders")
        let result = buildAppHealthResult(
            "reminders-bridge", health: health,
            notInstalled: "Reminders is not installed",
            notRunning: "Reminders is not running")
        return try responseJSON(["ok": true, "result": result])
    }

    routes.get("schema") { req -> Response in
        let schema: [String: Any] = [
            "ok": true,
            "result": [
                "app": "reminders-bridge",
                "endpoints": [
                    [
                        "method": "GET",
                        "path": "/reminders/lists",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/reminders/reminders",
                        "params": [
                            ["name": "listId", "from": "query", "type": "string"],
                            ["name": "completed", "from": "query", "type": "boolean"],
                            ["name": "limit", "from": "query", "type": "number", "default": 50],
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/reminders/reminder",
                        "params": [
                            ["name": "id", "from": "query", "type": "string", "required": true]
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/reminders/reminders",
                        "params": [
                            ["name": "name", "from": "body", "type": "string", "required": true],
                            ["name": "notes", "from": "body", "type": "string"],
                            ["name": "listId", "from": "body", "type": "string"],
                            ["name": "dueDate", "from": "body", "type": "string"],
                            ["name": "remindMeDate", "from": "body", "type": "string"],
                            ["name": "priority", "from": "body", "type": "number"],
                            ["name": "flagged", "from": "body", "type": "boolean"],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/reminders/reminders/complete",
                        "params": [
                            ["name": "ids", "from": "body", "type": "string[]", "required": true],
                            [
                                "name": "completed", "from": "body", "type": "boolean",
                                "required": true,
                            ],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/reminders/reminders/delete",
                        "params": [
                            ["name": "ids", "from": "body", "type": "string[]", "required": true]
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/reminders/help",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/reminders/health",
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

    routes.get("reminders") { req async throws -> Response in
        let listId = req.query[String.self, at: "listId"]
        let completed: Bool?
        if let completedStr = req.query[String.self, at: "completed"] {
            completed = completedStr == "true"
        } else {
            completed = nil
        }
        let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)

        let reminders = try await api.getReminders(listId: listId, completed: completed, limit: limit)
        return try responseJSON(["ok": true, "result": reminders])
    }

    routes.get("reminder") { req async throws -> Response in
        guard let id = req.query[String.self, at: "id"] else {
            throw Abort(.badRequest, reason: "'id' parameter is required")
        }
        let reminder = try await api.getReminder(id: id)
        return try responseJSON(["ok": true, "result": reminder as Any])
    }

    routes.post("reminders") { req async throws -> Response in
        struct CreateReminderRequest: Content {
            let name: String
            let notes: String?
            let listId: String?
            let dueDate: String?
            let remindMeDate: String?
            let priority: Int?
            let flagged: Bool?
        }

        let body = try req.content.decode(CreateReminderRequest.self)
        let result = try await api.createReminder(
            name: body.name, notes: body.notes, listId: body.listId,
            dueDate: body.dueDate, remindMeDate: body.remindMeDate,
            priority: body.priority, flagged: body.flagged)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("reminders", "complete") { req async throws -> Response in
        struct CompleteRequest: Content {
            let ids: [String]
            let completed: Bool
        }

        let body = try req.content.decode(CompleteRequest.self)
        let result = try await api.completeReminders(ids: body.ids, completed: body.completed)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("reminders", "delete") { req async throws -> Response in
        struct DeleteRequest: Content {
            let ids: [String]
        }

        let body = try req.content.decode(DeleteRequest.self)
        let result = try await api.deleteReminders(ids: body.ids)
        return try responseJSON(["ok": true, "result": result])
    }
}
