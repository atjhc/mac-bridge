import BridgeCore
import Vapor

func registerMessagesRoutes(on routes: RoutesBuilder, api: MessagesAPI) {
    routes.get("help") { req -> Response in
        let markdown = """
            # Messages Bridge API

            HTTP bridge to macOS Messages.

            ## Response format

            All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

            Messages must be running for this bridge to work.

            **Note:** The Messages scripting interface does not provide access to message content or history. You can list chats, see participants, and send new messages.

            ## Endpoints

            ### GET /messages/chats
            List all chats with participant names. Returns `id`, `name`, `participants`.

            ### GET /messages/chat
            Get a single chat with participant details.
            - `id` (required)

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
        return try responseJSON(schema)
    }

    routes.get("chats") { req throws -> Response in
        let chats = try api.getChats()
        return try responseJSON(["ok": true, "result": chats])
    }

    routes.get("chat") { req throws -> Response in
        guard let id = req.query[String.self, at: "id"] else {
            throw Abort(.badRequest, reason: "'id' parameter is required")
        }
        let chat = try api.getChat(id: id)
        return try responseJSON(["ok": true, "result": chat as Any])
    }

    routes.get("participants") { req throws -> Response in
        let participants = try api.getParticipants()
        return try responseJSON(["ok": true, "result": participants])
    }

    routes.post("send") { req throws -> Response in
        struct SendRequest: Content {
            let chatId: String?
            let participantId: String?
            let body: String
        }

        let body = try req.content.decode(SendRequest.self)
        guard body.chatId != nil || body.participantId != nil else {
            throw Abort(.badRequest, reason: "'chatId' or 'participantId' is required")
        }
        let result = try api.send(
            chatId: body.chatId, participantId: body.participantId, body: body.body)
        return try responseJSON(["ok": true, "result": result])
    }
}
