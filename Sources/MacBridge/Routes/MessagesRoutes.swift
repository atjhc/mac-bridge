import BridgeCore
import Vapor

func registerMessagesRoutes(on routes: RoutesBuilder, api: MessagesAPI, policy: EndpointPolicy) {
    routes.get("help") { req -> Response in
        let markdown = """
            # Messages Bridge API

            HTTP bridge to macOS Messages.

            ## Response format

            All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

            Messages must be running for this bridge to work.

            Messages must be running for chat listing and sending. Message history is read directly from the Messages database and requires Full Disk Access.

            ## Endpoints

            ### GET /messages/chats
            List all chats with participant names. Returns `id`, `name`, `participants`.

            ### GET /messages/chat
            Get a single chat with participant details.
            - `id` (required)

            ### GET /messages/messages
            Get message transcript for a chat. Reads from the Messages SQLite database.
            - `chatId` (required) — chat ID (from /chats) or phone number/email
            - `limit` (default: 50, max: 200)
            - `offset` (default: 0) — skip this many messages for pagination
            - `before` — ISO 8601 date; only return messages before this time

            Returns messages in chronological order: `guid`, `text`, `isFromMe`, `date`, `service`, `sender`. Tapbacks include `reactionType` and `reactionTo`.

            ### GET /messages/participants
            List all known participants across chats. Returns `id`, `name`, `handle`, `fullName`.

            ### POST /messages/send
            Send a message.
            - `chatId` — target chat ID (provide chatId or participantId)
            - `participantId` — target participant ID
            - `body` (required) — message text

            ### GET /messages/health
            Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

            ### GET /messages/schema
            Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
            """
        return try responseJSON(["ok": true, "result": ["help": markdown]])
    }

    routes.get("health") { req -> Response in
        let health = checkAppHealth(bundleIdentifier: "com.apple.MobileSMS")
        let result = buildAppHealthResult(
            "messages-bridge", health: health,
            notInstalled: "Messages is not installed",
            notRunning: "Messages is not running")
        return try responseJSON(["ok": true, "result": result])
    }

    routes.get("schema") { req -> Response in
        let schema: [String: Any] = [
            "ok": true,
            "result": [
                "app": "messages-bridge",
                "endpoints": [
                    [
                        "method": "GET",
                        "path": "/messages/chats",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/messages/chat",
                        "params": [
                            ["name": "id", "from": "query", "type": "string", "required": true]
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/messages/messages",
                        "params": [
                            [
                                "name": "chatId", "from": "query", "type": "string",
                                "required": true,
                            ],
                            ["name": "limit", "from": "query", "type": "number", "default": 50],
                            ["name": "offset", "from": "query", "type": "number", "default": 0],
                            ["name": "before", "from": "query", "type": "string"],
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/messages/participants",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "POST",
                        "path": "/messages/send",
                        "params": [
                            ["name": "chatId", "from": "body", "type": "string"],
                            ["name": "participantId", "from": "body", "type": "string"],
                            ["name": "body", "from": "body", "type": "string", "required": true],
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/messages/help",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/messages/health",
                        "params": [] as [[String: Any]],
                    ],
                ],
            ],
        ]
        return try responseJSON(policy.filterSchema(schema, prefix: "messages"))
    }

    routes.get("chats") { req async throws -> Response in
        let chats = try await api.getChats()
        return try responseJSON(["ok": true, "result": chats])
    }

    routes.get("chat") { req async throws -> Response in
        guard let id = req.query[String.self, at: "id"] else {
            throw Abort(.badRequest, reason: "'id' parameter is required")
        }
        let chat = try await api.getChat(id: id)
        return try responseJSON(["ok": true, "result": chat as Any])
    }

    routes.get("messages") { req async throws -> Response in
        guard let chatId = req.query[String.self, at: "chatId"] else {
            throw Abort(.badRequest, reason: "'chatId' parameter is required")
        }
        let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)
        let offset = max(req.query[Int.self, at: "offset"] ?? 0, 0)
        let before = req.query[String.self, at: "before"]
            .flatMap { ISO8601DateFormatter().date(from: $0) }

        let result = try await api.getMessages(
            chatId: chatId, limit: limit, offset: offset, before: before)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.get("participants") { req async throws -> Response in
        let participants = try await api.getParticipants()
        return try responseJSON(["ok": true, "result": participants])
    }

    routes.post("send") { req async throws -> Response in
        struct SendRequest: Content {
            let chatId: String?
            let participantId: String?
            let body: String
        }

        let body = try req.content.decode(SendRequest.self)
        guard body.chatId != nil || body.participantId != nil else {
            throw Abort(.badRequest, reason: "'chatId' or 'participantId' is required")
        }
        let result = try await api.send(
            chatId: body.chatId, participantId: body.participantId, body: body.body)
        return try responseJSON(["ok": true, "result": result])
    }
}
