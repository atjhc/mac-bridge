import Foundation
import OSLog
import Vapor
import BridgeCore

let logger = os.Logger(subsystem: "com.user.bridge", category: "reminders")

let app = try Application(.detect())
defer { app.shutdown() }

app.logger.logLevel = .notice

let remindersAPI = RemindersAPI()

let rateLimit = Int(Environment.get("RATE_LIMIT_PER_SECOND") ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)
app.middleware.use(RateLimitMiddleware(limiter: rateLimiter, log: logger))
app.middleware.use(LoggingMiddleware(log: logger))
app.middleware.use(FormatMiddleware())

// Help endpoint
app.get("help") { req -> Response in
    let markdown = """
        # Reminders Bridge API

        HTTP bridge to macOS Reminders.

        ## Response format

        All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

        Reminders must be running for this bridge to work.

        ## Endpoints

        ### GET /lists
        List all reminder lists. Returns `id`, `name`, `color`, `emblem`.

        ### GET /reminders
        List reminders with optional filters.
        - `listId` — filter by list
        - `completed` — filter by completion status (true/false)
        - `limit` (default: 50, max: 200)

        Returns: `id`, `name`, `completed`, `priority`, `flagged`, `body`, `dueDate`, `remindMeDate`, `listId`, `listName`

        ### GET /reminder
        Get a single reminder with full details.
        - `id` (required)

        ### POST /reminders
        Create a new reminder.
        - `name` (required) — reminder title
        - `notes` — body text
        - `listId` — target list (uses default list if omitted)
        - `dueDate` — ISO date string
        - `remindMeDate` — ISO date-time string
        - `priority` — integer (0=none, 1=high, 5=medium, 9=low)
        - `flagged` — boolean

        ### POST /reminders/complete
        Mark reminders as complete or incomplete.
        - `ids` (required) — array of reminder ID strings
        - `completed` (required) — boolean

        ### POST /reminders/delete
        Delete reminders by ID.
        - `ids` (required) — array of reminder ID strings

        ### GET /health
        Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

        ### GET /schema
        Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
        """
    return try responseJSON(["ok": true, "result": ["help": markdown]])
}

// Health check
app.get("health") { req -> Response in
    let health = checkAppHealth(bundleIdentifier: "com.apple.reminders")
    var result: [String: Any] = [
        "app": "reminders-bridge",
        "appInstalled": health.installed,
        "appRunning": health.running,
    ]
    if health.isHealthy {
        result["status"] = "ok"
    } else if !health.installed {
        result["status"] = "error"
        result["error"] = "Reminders is not installed"
    } else {
        result["status"] = "error"
        result["error"] = "Reminders is not running"
    }
    return try responseJSON(["ok": true, "result": result])
}

// Schema endpoint
app.get("schema") { req -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "reminders-bridge",
            "endpoints": [
                [
                    "method": "GET",
                    "path": "/lists",
                    "params": [],
                ],
                [
                    "method": "GET",
                    "path": "/reminders",
                    "params": [
                        ["name": "listId", "from": "query", "type": "string"],
                        ["name": "completed", "from": "query", "type": "boolean"],
                        ["name": "limit", "from": "query", "type": "number", "default": 50],
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/reminder",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/reminders",
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
                    "path": "/reminders/complete",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "completed", "from": "body", "type": "boolean", "required": true],
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/reminders/delete",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true]
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/help",
                    "params": [],
                ],
                [
                    "method": "GET",
                    "path": "/health",
                    "params": [],
                ],
            ],
        ],
    ]
    return try responseJSON(schema)
}

// GET /lists
app.get("lists") { req throws -> Response in
    let lists = try remindersAPI.getLists()
    return try responseJSON(["ok": true, "result": lists])
}

// GET /reminders
app.get("reminders") { req throws -> Response in
    let listId = req.query[String.self, at: "listId"]
    let completed: Bool?
    if let completedStr = req.query[String.self, at: "completed"] {
        completed = completedStr == "true"
    } else {
        completed = nil
    }
    let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)

    let reminders = try remindersAPI.getReminders(listId: listId, completed: completed, limit: limit)
    return try responseJSON(["ok": true, "result": reminders])
}

// GET /reminder
app.get("reminder") { req throws -> Response in
    guard let id = req.query[String.self, at: "id"] else {
        throw Abort(.badRequest, reason: "'id' parameter is required")
    }
    let reminder = try remindersAPI.getReminder(id: id)
    return try responseJSON(["ok": true, "result": reminder as Any])
}

// POST /reminders
app.post("reminders") { req throws -> Response in
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
    let result = try remindersAPI.createReminder(
        name: body.name, notes: body.notes, listId: body.listId,
        dueDate: body.dueDate, remindMeDate: body.remindMeDate,
        priority: body.priority, flagged: body.flagged)
    return try responseJSON(["ok": true, "result": result])
}

// POST /reminders/complete
app.post("reminders", "complete") { req throws -> Response in
    struct CompleteRequest: Content {
        let ids: [String]
        let completed: Bool
    }

    let body = try req.content.decode(CompleteRequest.self)
    let result = try remindersAPI.completeReminders(ids: body.ids, completed: body.completed)
    return try responseJSON(["ok": true, "result": result])
}

// POST /reminders/delete
app.post("reminders", "delete") { req throws -> Response in
    struct DeleteRequest: Content {
        let ids: [String]
    }

    let body = try req.content.decode(DeleteRequest.self)
    let result = try remindersAPI.deleteReminders(ids: body.ids)
    return try responseJSON(["ok": true, "result": result])
}

let port = Int(Environment.get("REMINDERS_BRIDGE_PORT") ?? "7337") ?? 7337
app.http.server.configuration.hostname = "0.0.0.0"
app.http.server.configuration.port = port

logger.notice("Listening on http://localhost:\(port)")
try app.run()
