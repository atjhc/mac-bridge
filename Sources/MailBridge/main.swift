import BridgeHTTP
import Hummingbird
import OSLog

let logger = Logger(subsystem: "com.user.bridge", category: "mail")

let mailAPI = MailBridgeAPI()

if let archiveConfig = ProcessInfo.processInfo.environment["ARCHIVE_MAILBOXES"] {
    for entry in archiveConfig.split(separator: ",") {
        let parts = entry.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        mailAPI.archiveMailboxes[String(parts[0])] = String(parts[1])
    }
}

let rateLimit = Int(ProcessInfo.processInfo.environment["RATE_LIMIT_PER_SECOND"] ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)

let router = Router()
router.add(middleware: BridgeRateLimitMiddleware(limiter: rateLimiter, log: logger))
router.add(middleware: BridgeLoggingMiddleware(log: logger))
router.add(middleware: BridgeFormatMiddleware())

router.get("help") { _, _ -> Response in
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

        Use `GET /accounts` to discover available account names, then pass them as the `account` parameter.

        ## Endpoints

        ### GET /accounts
        List all mail accounts.

        ### GET /mailboxes
        List mailboxes. Optional: `account` to filter by account.

        ### GET /messages
        List messages, sorted newest-first.
        - `mailbox` (default: INBOX) — mailbox name
        - `account` — account name
        - `unread` (default: false) — only unread messages
        - `flagged` (default: false) — only flagged messages
        - `search` — filter by subject or sender substring
        - `limit` (default: 50, max: 200) — number of messages
        - `offset` (default: 0) — skip this many messages

        Returns: `id`, `messageId`, `subject`, `sender`, `dateReceived`, `read`, `flagged`

        ### GET /message
        Get a single message with full content.
        - `id` (required) — integer id or messageId string
        - `mailbox` (default: INBOX)
        - `account`
        - `includeSource` (default: false) — include raw RFC 2822 source

        Returns: same fields as /messages plus `content` (plain text body) and optionally `source`.

        ### POST /messages/read
        Mark messages as read or unread.
        - `ids` (required) — array of id or messageId strings
        - `read` (default: true) — false to mark unread
        - `mailbox` (default: INBOX)
        - `account`

        ### POST /messages/flag
        Flag or unflag messages.
        - `ids` (required)
        - `flagged` (default: true)
        - `mailbox` (default: INBOX)
        - `account`

        ### POST /messages/move
        Move messages to a different mailbox.
        - `ids` (required)
        - `mailbox` (required) — destination mailbox name
        - `account` — destination account
        - `fromMailbox` (default: INBOX) — source mailbox
        - `fromAccount` — source account

        ### POST /messages/archive
        Move messages to the account's archive mailbox. The bridge automatically resolves the correct archive mailbox per account (e.g. "Archive" for iCloud, "All Mail" for Gmail).
        - `ids` (required)
        - `mailbox` (default: INBOX) — source mailbox
        - `account` — **always specify this**; archive destination varies by account

        Group archive calls by account. Do not mix ids from different accounts in a single call.

        ### POST /messages/delete
        Permanently delete messages.
        - `ids` (required)
        - `mailbox` (default: INBOX)
        - `account`

        ### POST /compose
        Send a new email via Mail.app.
        - `to` (required) — recipient email address
        - `subject` (required)
        - `body` (required) — plain text body
        - `cc` — CC recipient

        ### GET /health
        Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

        ### GET /schema
        Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
        """
    return try bridgeResponse(["ok": true, "result": ["help": markdown]])
}

router.get("health") { _, _ -> Response in
    let result = mailAPI.healthCheck()
    let isOk = (result["status"] as? String) == "ok"
    return try bridgeResponse(["ok": isOk, "result": result])
}

router.get("schema") { _, _ -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "mail-bridge",
            "endpoints": [
                ["method": "GET", "path": "/accounts", "params": []],
                [
                    "method": "GET", "path": "/mailboxes",
                    "params": [
                        ["name": "account", "from": "query", "type": "string"]
                    ],
                ],
                [
                    "method": "GET", "path": "/messages",
                    "params": [
                        ["name": "mailbox", "from": "query", "type": "string", "default": "INBOX"],
                        ["name": "account", "from": "query", "type": "string"],
                        ["name": "unread", "from": "query", "type": "boolean", "default": false],
                        ["name": "flagged", "from": "query", "type": "boolean", "default": false],
                        ["name": "search", "from": "query", "type": "string"],
                        ["name": "limit", "from": "query", "type": "number", "default": 50],
                        ["name": "offset", "from": "query", "type": "number", "default": 0],
                    ],
                ],
                [
                    "method": "GET", "path": "/message",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true],
                        ["name": "mailbox", "from": "query", "type": "string", "default": "INBOX"],
                        ["name": "account", "from": "query", "type": "string"],
                        [
                            "name": "includeSource", "from": "query", "type": "boolean",
                            "default": false,
                        ],
                    ],
                ],
                [
                    "method": "POST", "path": "/messages/read",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "read", "from": "body", "type": "boolean", "default": true],
                        ["name": "mailbox", "from": "body", "type": "string", "default": "INBOX"],
                        ["name": "account", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST", "path": "/messages/flag",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "flagged", "from": "body", "type": "boolean", "default": true],
                        ["name": "mailbox", "from": "body", "type": "string", "default": "INBOX"],
                        ["name": "account", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST", "path": "/messages/move",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "mailbox", "from": "body", "type": "string", "required": true],
                        ["name": "account", "from": "body", "type": "string"],
                        [
                            "name": "fromMailbox", "from": "body", "type": "string",
                            "default": "INBOX",
                        ],
                        ["name": "fromAccount", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST", "path": "/messages/archive",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "mailbox", "from": "body", "type": "string", "default": "INBOX"],
                        ["name": "account", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST", "path": "/messages/delete",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "mailbox", "from": "body", "type": "string", "default": "INBOX"],
                        ["name": "account", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST", "path": "/compose",
                    "params": [
                        ["name": "to", "from": "body", "type": "string", "required": true],
                        ["name": "subject", "from": "body", "type": "string", "required": true],
                        ["name": "body", "from": "body", "type": "string", "required": true],
                        ["name": "cc", "from": "body", "type": "string"],
                    ],
                ],
                ["method": "GET", "path": "/help", "params": []],
                ["method": "GET", "path": "/health", "params": []],
            ],
        ],
    ]
    return try bridgeResponse(schema)
}

router.get("accounts") { _, _ -> Response in
    let accounts = mailAPI.getAccounts()
    return try bridgeResponse(["ok": true, "result": accounts])
}

router.get("mailboxes") { req, _ -> Response in
    let account: String? = req.uri.queryParameters.get("account")
    let mailboxes = mailAPI.getMailboxes(account: account)
    return try bridgeResponse(["ok": true, "result": mailboxes])
}

router.get("messages") { req, _ -> Response in
    let mailbox = req.uri.queryParameters.get("mailbox") ?? "INBOX"
    let account: String? = req.uri.queryParameters.get("account")
    let unread = req.uri.queryParameters.get("unread") == "true"
    let flagged = req.uri.queryParameters.get("flagged") == "true"
    let search: String? = req.uri.queryParameters.get("search")
    let limit = min(Int(req.uri.queryParameters.get("limit") ?? "") ?? 50, 200)
    let offset = Int(req.uri.queryParameters.get("offset") ?? "") ?? 0

    let messages = mailAPI.getMessages(
        mailbox: mailbox, account: account, unread: unread, flagged: flagged,
        search: search, limit: limit, offset: offset)

    return try bridgeResponse(["ok": true, "result": messages])
}

router.get("message") { req, _ -> Response in
    guard let id: String = req.uri.queryParameters.get("id") else {
        throw HTTPError(.badRequest, message: "'id' parameter is required")
    }

    let mailbox = req.uri.queryParameters.get("mailbox") ?? "INBOX"
    let account: String? = req.uri.queryParameters.get("account")
    let includeSource = req.uri.queryParameters.get("includeSource") == "true"

    let message = mailAPI.getMessage(
        id: id, mailbox: mailbox, account: account, includeSource: includeSource)

    return try bridgeResponse(["ok": true, "result": message as Any])
}

router.post("messages/read") { req, ctx -> Response in
    struct SetReadStatusRequest: Decodable {
        let ids: [String]
        let read: Bool?
        let mailbox: String?
        let account: String?
    }

    let body = try await req.decode(as: SetReadStatusRequest.self, context: ctx)
    let updated = mailAPI.setReadStatus(
        ids: body.ids, read: body.read ?? true,
        mailbox: body.mailbox ?? "INBOX", account: body.account)

    return try bridgeResponse(["ok": true, "result": ["updated": updated]])
}

router.post("messages/flag") { req, ctx -> Response in
    struct SetFlaggedStatusRequest: Decodable {
        let ids: [String]
        let flagged: Bool?
        let mailbox: String?
        let account: String?
    }

    let body = try await req.decode(as: SetFlaggedStatusRequest.self, context: ctx)
    let updated = mailAPI.setFlaggedStatus(
        ids: body.ids, flagged: body.flagged ?? true,
        mailbox: body.mailbox ?? "INBOX", account: body.account)

    return try bridgeResponse(["ok": true, "result": ["updated": updated]])
}

router.post("messages/move") { req, ctx -> Response in
    struct MoveMessagesRequest: Decodable {
        let ids: [String]
        let mailbox: String
        let account: String?
        let fromMailbox: String?
        let fromAccount: String?
    }

    let body = try await req.decode(as: MoveMessagesRequest.self, context: ctx)
    let result = mailAPI.moveMessages(
        ids: body.ids, toMailbox: body.mailbox, toAccount: body.account,
        fromMailbox: body.fromMailbox ?? "INBOX", fromAccount: body.fromAccount)

    if let error = result.error {
        return try bridgeResponse(["ok": false, "error": error])
    }

    return try bridgeResponse(["ok": true, "result": ["moved": result.moved]])
}

router.post("messages/archive") { req, ctx -> Response in
    struct ArchiveMessagesRequest: Decodable {
        let ids: [String]
        let mailbox: String?
        let account: String?
    }

    let body = try await req.decode(as: ArchiveMessagesRequest.self, context: ctx)
    let result = mailAPI.archiveMessages(
        ids: body.ids, mailbox: body.mailbox ?? "INBOX", account: body.account)

    if let error = result.error {
        return try bridgeResponse(["ok": false, "error": error])
    }

    return try bridgeResponse(["ok": true, "result": ["archived": result.archived]])
}

router.post("messages/delete") { req, ctx -> Response in
    struct DeleteMessagesRequest: Decodable {
        let ids: [String]
        let mailbox: String?
        let account: String?
    }

    let body = try await req.decode(as: DeleteMessagesRequest.self, context: ctx)
    let deleted = mailAPI.deleteMessages(
        ids: body.ids, mailbox: body.mailbox ?? "INBOX", account: body.account)

    return try bridgeResponse(["ok": true, "result": ["deleted": deleted]])
}

router.post("compose") { req, ctx -> Response in
    struct ComposeMessageRequest: Decodable {
        let to: String
        let subject: String
        let body: String
        let cc: String?
    }

    let body = try await req.decode(as: ComposeMessageRequest.self, context: ctx)
    let result = mailAPI.composeMessage(
        to: body.to, subject: body.subject, body: body.body, cc: body.cc)

    if let error = result.error {
        return try bridgeResponse(["ok": false, "error": error])
    }

    return try bridgeResponse(["ok": true, "result": ["sent": result.sent]])
}

let port = Int(ProcessInfo.processInfo.environment["MAIL_BRIDGE_PORT"] ?? "7333") ?? 7333
logger.notice("Listening on http://localhost:\(port)")

let app = Application(
    router: router,
    configuration: .init(address: .hostname("0.0.0.0", port: port))
)
try await app.runService()
