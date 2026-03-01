import BridgeCore
import Vapor

func registerMailRoutes(on routes: RoutesBuilder, api: MailBridgeAPI) {
    routes.get("help") { req -> Response in
        let markdown = """
            # Mail Bridge API

            HTTP bridge to Apple Mail via ScriptingBridge.

            ## Response format

            All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}` on success and `{"ok": false, "error": "..."}` on failure.

            ## Message identifiers

            Messages have two IDs:
            - `id` — Mail.app's internal integer ID. Fast but **ephemeral**: changes when a message is moved between mailboxes.
            - `messageId` — The RFC 2822 Message-ID header (e.g. `<abc123@example.com>`). **Permanent and globally unique**. Prefer this for any operation where there may be a delay between fetching and acting.

            All action endpoints accept either type in the `ids` array. The bridge auto-detects: values containing `@` are treated as messageId, otherwise as integer id. You can mix both types in a single call.

            ## Multi-account usage

            This bridge supports multiple mail accounts (e.g. iCloud, Gmail). Most endpoints accept an optional `account` parameter. If omitted, the bridge uses the default account or searches across all accounts. Always specify `account` when operating on a specific mailbox to avoid ambiguity.

            Use `GET /mail/accounts` to discover available account names, then pass them as the `account` parameter.

            ## Endpoints

            ### GET /mail/accounts
            List all mail accounts.

            ### GET /mail/mailboxes
            List mailboxes. Optional: `account` to filter by account.

            ### GET /mail/messages
            List messages, sorted newest-first.
            - `mailbox` (default: INBOX) — mailbox name
            - `account` — account name
            - `unread` (default: false) — only unread messages
            - `flagged` (default: false) — only flagged messages
            - `search` — filter by subject or sender substring
            - `limit` (default: 50, max: 200) — number of messages
            - `offset` (default: 0) — skip this many messages

            Returns: `id`, `messageId`, `subject`, `sender`, `dateReceived`, `read`, `flagged`

            ### GET /mail/message
            Get a single message with full content.
            - `id` (required) — integer id or messageId string
            - `mailbox` (default: INBOX)
            - `account`
            - `includeSource` (default: false) — include raw RFC 2822 source

            Returns: same fields as /messages plus `content` (plain text body) and optionally `source`.

            ### POST /mail/messages/read
            Mark messages as read or unread.
            - `ids` (required) — array of id or messageId strings
            - `read` (default: true) — false to mark unread
            - `mailbox` (default: INBOX)
            - `account`

            ### POST /mail/messages/flag
            Flag or unflag messages.
            - `ids` (required)
            - `flagged` (default: true)
            - `mailbox` (default: INBOX)
            - `account`

            ### POST /mail/messages/move
            Move messages to a different mailbox.
            - `ids` (required)
            - `mailbox` (required) — destination mailbox name
            - `account` — destination account
            - `fromMailbox` (default: INBOX) — source mailbox
            - `fromAccount` — source account

            ### POST /mail/messages/archive
            Move messages to the account's archive mailbox. The bridge automatically resolves the correct archive mailbox per account (e.g. "Archive" for iCloud, "All Mail" for Gmail).
            - `ids` (required)
            - `mailbox` (default: INBOX) — source mailbox
            - `account` — **always specify this**; archive destination varies by account

            Group archive calls by account. Do not mix ids from different accounts in a single call.

            ### POST /mail/messages/delete
            Permanently delete messages.
            - `ids` (required)
            - `mailbox` (default: INBOX)
            - `account`

            ### POST /mail/compose
            Send a new email via Mail.app.
            - `to` (required) — recipient email address
            - `subject` (required)
            - `body` (required) — plain text body
            - `cc` — CC recipient

            ### GET /mail/health
            Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

            ### GET /mail/schema
            Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
            """
        return try responseJSON(["ok": true, "result": ["help": markdown]])
    }

    routes.get("health") { req -> Response in
        let health = checkAppHealth(bundleIdentifier: "com.apple.mail")
        let result = buildAppHealthResult(
            "mail-bridge", health: health,
            notInstalled: "Mail.app is not installed",
            notRunning: "Mail.app is not running")
        return try responseJSON(["ok": true, "result": result])
    }

    routes.get("schema") { req -> Response in
        let schema: [String: Any] = [
            "ok": true,
            "result": [
                "app": "mail-bridge",
                "endpoints": [
                    [
                        "method": "GET",
                        "path": "/mail/accounts",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/mail/mailboxes",
                        "params": [
                            ["name": "account", "from": "query", "type": "string"]
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/mail/messages",
                        "params": [
                            [
                                "name": "mailbox", "from": "query", "type": "string",
                                "default": "INBOX",
                            ],
                            ["name": "account", "from": "query", "type": "string"],
                            [
                                "name": "unread", "from": "query", "type": "boolean",
                                "default": false,
                            ],
                            [
                                "name": "flagged", "from": "query", "type": "boolean",
                                "default": false,
                            ],
                            ["name": "search", "from": "query", "type": "string"],
                            ["name": "limit", "from": "query", "type": "number", "default": 50],
                            ["name": "offset", "from": "query", "type": "number", "default": 0],
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/mail/message",
                        "params": [
                            ["name": "id", "from": "query", "type": "string", "required": true],
                            [
                                "name": "mailbox", "from": "query", "type": "string",
                                "default": "INBOX",
                            ],
                            ["name": "account", "from": "query", "type": "string"],
                            [
                                "name": "includeSource", "from": "query", "type": "boolean",
                                "default": false,
                            ],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/mail/messages/read",
                        "params": [
                            ["name": "ids", "from": "body", "type": "string[]", "required": true],
                            ["name": "read", "from": "body", "type": "boolean", "default": true],
                            [
                                "name": "mailbox", "from": "body", "type": "string",
                                "default": "INBOX",
                            ],
                            ["name": "account", "from": "body", "type": "string"],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/mail/messages/flag",
                        "params": [
                            ["name": "ids", "from": "body", "type": "string[]", "required": true],
                            [
                                "name": "flagged", "from": "body", "type": "boolean",
                                "default": true,
                            ],
                            [
                                "name": "mailbox", "from": "body", "type": "string",
                                "default": "INBOX",
                            ],
                            ["name": "account", "from": "body", "type": "string"],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/mail/messages/move",
                        "params": [
                            ["name": "ids", "from": "body", "type": "string[]", "required": true],
                            [
                                "name": "mailbox", "from": "body", "type": "string",
                                "required": true,
                            ],
                            ["name": "account", "from": "body", "type": "string"],
                            [
                                "name": "fromMailbox", "from": "body", "type": "string",
                                "default": "INBOX",
                            ],
                            ["name": "fromAccount", "from": "body", "type": "string"],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/mail/messages/archive",
                        "params": [
                            ["name": "ids", "from": "body", "type": "string[]", "required": true],
                            [
                                "name": "mailbox", "from": "body", "type": "string",
                                "default": "INBOX",
                            ],
                            ["name": "account", "from": "body", "type": "string"],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/mail/messages/delete",
                        "params": [
                            ["name": "ids", "from": "body", "type": "string[]", "required": true],
                            [
                                "name": "mailbox", "from": "body", "type": "string",
                                "default": "INBOX",
                            ],
                            ["name": "account", "from": "body", "type": "string"],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/mail/compose",
                        "params": [
                            ["name": "to", "from": "body", "type": "string", "required": true],
                            [
                                "name": "subject", "from": "body", "type": "string",
                                "required": true,
                            ],
                            ["name": "body", "from": "body", "type": "string", "required": true],
                            ["name": "cc", "from": "body", "type": "string"],
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/mail/help",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/mail/health",
                        "params": [] as [[String: Any]],
                    ],
                ],
            ],
        ]
        return try responseJSON(schema)
    }

    routes.get("accounts") { req -> Response in
        let accounts = api.getAccounts()
        return try responseJSON(["ok": true, "result": accounts])
    }

    routes.get("mailboxes") { req -> Response in
        let account = req.query[String.self, at: "account"]
        let mailboxes = api.getMailboxes(account: account)
        return try responseJSON(["ok": true, "result": mailboxes])
    }

    routes.get("messages") { req -> Response in
        let mailbox = req.query[String.self, at: "mailbox"] ?? "INBOX"
        let account = req.query[String.self, at: "account"]
        let unread = req.query[Bool.self, at: "unread"] ?? false
        let flagged = req.query[Bool.self, at: "flagged"] ?? false
        let search = req.query[String.self, at: "search"]
        let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)
        let offset = req.query[Int.self, at: "offset"] ?? 0

        let messages = api.getMessages(
            mailbox: mailbox, account: account, unread: unread, flagged: flagged,
            search: search, limit: limit, offset: offset)

        return try responseJSON(["ok": true, "result": messages])
    }

    routes.get("message") { req -> Response in
        guard let id = req.query[String.self, at: "id"] else {
            throw Abort(.badRequest, reason: "'id' parameter is required")
        }

        let mailbox = req.query[String.self, at: "mailbox"] ?? "INBOX"
        let account = req.query[String.self, at: "account"]
        let includeSource = req.query[Bool.self, at: "includeSource"] ?? false

        let message = api.getMessage(
            id: id, mailbox: mailbox, account: account, includeSource: includeSource)

        return try responseJSON(["ok": true, "result": message as Any])
    }

    routes.post("messages", "read") { req async throws -> Response in
        struct SetReadStatusRequest: Content {
            let ids: [String]
            let read: Bool?
            let mailbox: String?
            let account: String?
        }

        let body = try req.content.decode(SetReadStatusRequest.self)
        let updated = api.setReadStatus(
            ids: body.ids, read: body.read ?? true,
            mailbox: body.mailbox ?? "INBOX", account: body.account)

        return try responseJSON(["ok": true, "result": ["updated": updated]])
    }

    routes.post("messages", "flag") { req async throws -> Response in
        struct SetFlaggedStatusRequest: Content {
            let ids: [String]
            let flagged: Bool?
            let mailbox: String?
            let account: String?
        }

        let body = try req.content.decode(SetFlaggedStatusRequest.self)
        let updated = api.setFlaggedStatus(
            ids: body.ids, flagged: body.flagged ?? true,
            mailbox: body.mailbox ?? "INBOX", account: body.account)

        return try responseJSON(["ok": true, "result": ["updated": updated]])
    }

    routes.post("messages", "move") { req async throws -> Response in
        struct MoveMessagesRequest: Content {
            let ids: [String]
            let mailbox: String
            let account: String?
            let fromMailbox: String?
            let fromAccount: String?
        }

        let body = try req.content.decode(MoveMessagesRequest.self)
        let result = api.moveMessages(
            ids: body.ids, toMailbox: body.mailbox, toAccount: body.account,
            fromMailbox: body.fromMailbox ?? "INBOX", fromAccount: body.fromAccount)

        if let error = result.error {
            return try responseJSON(["ok": false, "error": error])
        }

        return try responseJSON(["ok": true, "result": ["moved": result.moved]])
    }

    routes.post("messages", "archive") { req async throws -> Response in
        struct ArchiveMessagesRequest: Content {
            let ids: [String]
            let mailbox: String?
            let account: String?
        }

        let body = try req.content.decode(ArchiveMessagesRequest.self)
        let result = api.archiveMessages(
            ids: body.ids, mailbox: body.mailbox ?? "INBOX", account: body.account)

        if let error = result.error {
            return try responseJSON(["ok": false, "error": error])
        }

        return try responseJSON(["ok": true, "result": ["archived": result.archived]])
    }

    routes.post("messages", "delete") { req async throws -> Response in
        struct DeleteMessagesRequest: Content {
            let ids: [String]
            let mailbox: String?
            let account: String?
        }

        let body = try req.content.decode(DeleteMessagesRequest.self)
        let deleted = api.deleteMessages(
            ids: body.ids, mailbox: body.mailbox ?? "INBOX", account: body.account)

        return try responseJSON(["ok": true, "result": ["deleted": deleted]])
    }

    routes.post("compose") { req async throws -> Response in
        struct ComposeMessageRequest: Content {
            let to: String
            let subject: String
            let body: String
            let cc: String?
        }

        let body = try req.content.decode(ComposeMessageRequest.self)
        let result = api.composeMessage(
            to: body.to, subject: body.subject, body: body.body, cc: body.cc)

        if let error = result.error {
            return try responseJSON(["ok": false, "error": error])
        }

        return try responseJSON(["ok": true, "result": ["sent": result.sent]])
    }
}
