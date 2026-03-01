import Foundation
import OSLog
import Vapor
import BridgeCore

let logger = os.Logger(subsystem: "com.user.bridge", category: "messages")

let app = try Application(.detect())
defer { app.shutdown() }

app.logger.logLevel = .notice

let messagesAPI = MessagesAPI()

let rateLimit = Int(Environment.get("RATE_LIMIT_PER_SECOND") ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)
app.middleware.use(RateLimitMiddleware(limiter: rateLimiter, log: logger))
app.middleware.use(LoggingMiddleware(log: logger))
app.middleware.use(FormatMiddleware())

// Help endpoint
app.get("help") { req -> Response in
    let markdown = """
        # Messages Bridge API

        HTTP bridge to macOS Messages.

        ## Response format

        All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

        Messages must be running for this bridge to work.

        **Note:** The Messages scripting interface does not provide access to message content or history. You can list chats, see participants, and send new messages.

        ## Endpoints

        ### GET /chats
        List all chats with participant names. Returns `id`, `name`, `participants`.

        ### GET /chat
        Get a single chat with participant details.
        - `id` (required)

        ### GET /participants
        List all known participants across chats. Returns `id`, `name`, `handle`, `fullName`.

        ### POST /send
        Send a message.
        - `chatId` — target chat ID (provide chatId or participantId)
        - `participantId` — target participant ID
        - `body` (required) — message text

        ### GET /health
        Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

        ### GET /schema
        Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
        """
    return try responseJSON(["ok": true, "result": ["help": markdown]])
}

// Health check
app.get("health") { req -> Response in
    let health = checkAppHealth(bundleIdentifier: "com.apple.MobileSMS")
    var result: [String: Any] = [
        "app": "messages-bridge",
        "appInstalled": health.installed,
        "appRunning": health.running,
    ]
    if health.isHealthy {
        result["status"] = "ok"
    } else if !health.installed {
        result["status"] = "error"
        result["error"] = "Messages is not installed"
    } else {
        result["status"] = "error"
        result["error"] = "Messages is not running"
    }
    return try responseJSON(["ok": true, "result": result])
}

// Schema endpoint
app.get("schema") { req -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "messages-bridge",
            "endpoints": [
                [
                    "method": "GET",
                    "path": "/chats",
                    "params": [],
                ],
                [
                    "method": "GET",
                    "path": "/chat",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/participants",
                    "params": [],
                ],
                [
                    "method": "POST",
                    "path": "/send",
                    "params": [
                        ["name": "chatId", "from": "body", "type": "string"],
                        ["name": "participantId", "from": "body", "type": "string"],
                        ["name": "body", "from": "body", "type": "string", "required": true],
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

// GET /chats
app.get("chats") { req throws -> Response in
    let chats = try messagesAPI.getChats()
    return try responseJSON(["ok": true, "result": chats])
}

// GET /chat
app.get("chat") { req throws -> Response in
    guard let id = req.query[String.self, at: "id"] else {
        throw Abort(.badRequest, reason: "'id' parameter is required")
    }
    let chat = try messagesAPI.getChat(id: id)
    return try responseJSON(["ok": true, "result": chat as Any])
}

// GET /participants
app.get("participants") { req throws -> Response in
    let participants = try messagesAPI.getParticipants()
    return try responseJSON(["ok": true, "result": participants])
}

// POST /send
app.post("send") { req throws -> Response in
    struct SendRequest: Content {
        let chatId: String?
        let participantId: String?
        let body: String
    }

    let body = try req.content.decode(SendRequest.self)
    guard body.chatId != nil || body.participantId != nil else {
        throw Abort(.badRequest, reason: "'chatId' or 'participantId' is required")
    }
    let result = try messagesAPI.send(chatId: body.chatId, participantId: body.participantId, body: body.body)
    return try responseJSON(["ok": true, "result": result])
}

let port = Int(Environment.get("MESSAGES_BRIDGE_PORT") ?? "7338") ?? 7338
app.http.server.configuration.hostname = "0.0.0.0"
app.http.server.configuration.port = port

logger.notice("Listening on http://localhost:\(port)")
try app.run()
