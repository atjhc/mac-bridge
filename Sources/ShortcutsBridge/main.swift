import Foundation
import OSLog
import Vapor
import BridgeCore

let logger = os.Logger(subsystem: "com.user.bridge", category: "shortcuts")

let app = try Application(.detect())
defer { app.shutdown() }

app.logger.logLevel = .notice

let shortcutsAPI = ShortcutsAPI()

let rateLimit = Int(Environment.get("RATE_LIMIT_PER_SECOND") ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)
app.middleware.use(RateLimitMiddleware(limiter: rateLimiter, log: logger))
app.middleware.use(LoggingMiddleware(log: logger))
app.middleware.use(FormatMiddleware())

// Help endpoint
app.get("help") { req -> Response in
    let markdown = """
        # Shortcuts Bridge API

        HTTP bridge to macOS Shortcuts.

        ## Response format

        All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

        Shortcuts must be available for this bridge to work.

        ## Endpoints

        ### GET /shortcuts
        List all shortcuts. Returns `id`, `name`, `subtitle`, `folder`, `acceptsInput`, `actionCount`.

        ### GET /shortcut
        Get a single shortcut's details.
        - `id` (required)

        ### GET /folders
        List all folders with shortcut counts. Returns `id`, `name`, `shortcutCount`.

        ### POST /run
        Run a shortcut by name or ID.
        - `name` — shortcut name (provide name or id)
        - `id` — shortcut ID
        - `input` — optional input string to pass to the shortcut

        Returns the shortcut's output result.

        ### GET /health
        Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

        ### GET /schema
        Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
        """
    return try responseJSON(["ok": true, "result": ["help": markdown]])
}

// Health check
app.get("health") { req -> Response in
    let health = checkAppHealth(bundleIdentifier: "com.apple.shortcuts")
    var result: [String: Any] = [
        "app": "shortcuts-bridge",
        "appInstalled": health.installed,
        "appRunning": health.running,
    ]
    if health.isHealthy {
        result["status"] = "ok"
    } else if !health.installed {
        result["status"] = "error"
        result["error"] = "Shortcuts is not installed"
    } else {
        result["status"] = "error"
        result["error"] = "Shortcuts is not running"
    }
    return try responseJSON(["ok": true, "result": result])
}

// Schema endpoint
app.get("schema") { req -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "shortcuts-bridge",
            "endpoints": [
                [
                    "method": "GET",
                    "path": "/shortcuts",
                    "params": [],
                ],
                [
                    "method": "GET",
                    "path": "/shortcut",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/folders",
                    "params": [],
                ],
                [
                    "method": "POST",
                    "path": "/run",
                    "params": [
                        ["name": "name", "from": "body", "type": "string"],
                        ["name": "id", "from": "body", "type": "string"],
                        ["name": "input", "from": "body", "type": "string"],
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

// GET /shortcuts
app.get("shortcuts") { req throws -> Response in
    let shortcuts = try shortcutsAPI.getShortcuts()
    return try responseJSON(["ok": true, "result": shortcuts])
}

// GET /shortcut
app.get("shortcut") { req throws -> Response in
    guard let id = req.query[String.self, at: "id"] else {
        throw Abort(.badRequest, reason: "'id' parameter is required")
    }
    let shortcut = try shortcutsAPI.getShortcut(id: id)
    return try responseJSON(["ok": true, "result": shortcut as Any])
}

// GET /folders
app.get("folders") { req throws -> Response in
    let folders = try shortcutsAPI.getFolders()
    return try responseJSON(["ok": true, "result": folders])
}

// POST /run
app.post("run") { req throws -> Response in
    struct RunRequest: Content {
        let name: String?
        let id: String?
        let input: String?
    }

    let body = try req.content.decode(RunRequest.self)
    guard body.name != nil || body.id != nil else {
        throw Abort(.badRequest, reason: "'name' or 'id' is required")
    }
    let result = try shortcutsAPI.runShortcut(name: body.name, id: body.id, input: body.input)
    return try responseJSON(["ok": true, "result": result])
}

let port = Int(Environment.get("SHORTCUTS_BRIDGE_PORT") ?? "7339") ?? 7339
app.http.server.configuration.hostname = "0.0.0.0"
app.http.server.configuration.port = port

logger.notice("Listening on http://localhost:\(port)")
try app.run()
