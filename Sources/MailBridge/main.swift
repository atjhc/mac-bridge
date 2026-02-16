import Foundation
import OSLog
import Vapor

let logger = os.Logger(subsystem: "com.user.bridge", category: "mail")

let app = try Application(.detect())
defer { app.shutdown() }

let mailAPI = MailBridgeAPI()

// Configure archive mailbox per account (format: "Account1=Mailbox,Account2=Mailbox")
if let archiveConfig = Environment.get("ARCHIVE_MAILBOXES") {
    for entry in archiveConfig.split(separator: ",") {
        let parts = entry.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        mailAPI.archiveMailboxes[String(parts[0])] = String(parts[1])
    }
}

// Suppress Vapor's verbose request logging - we have our own middleware
app.logger.logLevel = .notice

// Rate limiting middleware
actor RateLimiter {
    private var requests: [String: [Date]] = [:]
    private let limit: Int
    private let window: TimeInterval = 1.0  // 1 second

    init(limit: Int) {
        self.limit = limit
    }

    func checkLimit(for ip: String) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-window)

        requests[ip] = requests[ip]?.filter { $0 > cutoff } ?? []

        let count = requests[ip]?.count ?? 0
        if count >= limit {
            return false
        }

        requests[ip, default: []].append(now)
        return true
    }
}

struct RateLimitMiddleware: AsyncMiddleware {
    let limiter: RateLimiter
    let log: os.Logger

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let ip =
            request.headers.first(name: "X-Forwarded-For")
            ?? request.remoteAddress?.description ?? "unknown"

        let allowed = await limiter.checkLimit(for: ip)
        if !allowed {
            log.warning("Rate limit exceeded for \(ip, privacy: .public)")
            throw Abort(.tooManyRequests, reason: "Rate limit exceeded")
        }

        return try await next.respond(to: request)
    }
}

struct LoggingMiddleware: AsyncMiddleware {
    let log: os.Logger

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let start = Date()

        var logLine = "\(request.method) \(request.url.path)"
        if let query = request.url.query, !query.isEmpty {
            logLine += "?\(query)"
        }
        log.info("\(logLine, privacy: .public)")

        let response = try await next.respond(to: request)
        let duration = Date().timeIntervalSince(start) * 1000

        log.info("\(logLine, privacy: .public) → \(response.status.code) (\(Int(duration))ms)")

        return response
    }
}

struct FormatMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)

        let wantsJSON = request.query[String.self, at: "format"] == "json"
            || request.headers.first(name: .accept)?.contains("application/json") == true
        guard !wantsJSON else { return response }

        let contentType = response.headers.first(name: .contentType) ?? ""
        guard contentType.contains("application/json") else { return response }
        guard let body = response.body.data else { return response }

        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]

        if let ok = json["ok"] as? Bool, !ok {
            let message = json["error"] as? String ?? "Unknown error"
            return markdownResponse("**Error:** \(message)")
        }

        let result = json["result"]
        let markdown = jsonToMarkdown(result)

        return markdownResponse(markdown)
    }

    private func markdownResponse(_ text: String) -> Response {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/markdown; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: text))
    }
}

func jsonToMarkdown(_ value: Any?) -> String {
    guard let value else { return "No results." }

    if let dict = value as? [String: Any], let help = dict["help"] as? String {
        return help
    }

    if let array = value as? [[String: Any]], !array.isEmpty {
        return arrayToMarkdownTable(array)
    }

    if let dict = value as? [String: Any] {
        return objectToKeyValueList(dict)
    }

    if value is NSNull {
        return "No results."
    }

    return "\(value)"
}

func arrayToMarkdownTable(_ rows: [[String: Any]]) -> String {
    let keys = rows.first.map { $0.keys.sorted() } ?? []
    guard !keys.isEmpty else { return "No results." }

    var lines: [String] = []
    lines.append("| " + keys.joined(separator: " | ") + " |")
    lines.append("| " + keys.map { _ in "---" }.joined(separator: " | ") + " |")

    for row in rows {
        let cells = keys.map { formatCellValue(row[$0]) }
        lines.append("| " + cells.joined(separator: " | ") + " |")
    }

    return lines.joined(separator: "\n")
}

func objectToKeyValueList(_ dict: [String: Any]) -> String {
    guard !dict.isEmpty else { return "No results." }
    return dict.keys.sorted().map { key in
        "- **\(key):** \(formatCellValue(dict[key]))"
    }.joined(separator: "\n")
}

func formatCellValue(_ value: Any?) -> String {
    guard let value else { return "" }
    if value is NSNull { return "" }

    if let dict = value as? [String: Any] {
        return dict.keys.sorted().map { "\($0): \(formatCellValue(dict[$0]))" }
            .joined(separator: ", ")
    }

    if let array = value as? [Any] {
        return array.map { formatCellValue($0) }.joined(separator: ", ")
    }

    if let number = value as? NSNumber,
        CFGetTypeID(number) == CFBooleanGetTypeID()
    {
        return number.boolValue ? "true" : "false"
    }

    return "\(value)".replacingOccurrences(of: "|", with: "\\|")
        .replacingOccurrences(of: "\n", with: " ")
}

let rateLimit = Int(Environment.get("RATE_LIMIT_PER_SECOND") ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)
app.middleware.use(RateLimitMiddleware(limiter: rateLimiter, log: logger))
app.middleware.use(LoggingMiddleware(log: logger))
app.middleware.use(FormatMiddleware())

// Help endpoint
app.get("help") { req -> Response in
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
    return try responseJSON(["ok": true, "result": ["help": markdown]])
}

// Health check
app.get("health") { req -> Response in
    let response: [String: Any] = [
        "ok": true,
        "result": [
            "status": "ok",
            "app": "mail-bridge",
        ],
    ]
    return try responseJSON(response)
}

// Schema endpoint
app.get("schema") { req -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "mail-bridge",
            "endpoints": [
                [
                    "method": "GET",
                    "path": "/accounts",
                    "params": [],
                ],
                [
                    "method": "GET",
                    "path": "/mailboxes",
                    "params": [
                        ["name": "account", "from": "query", "type": "string"]
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/messages",
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
                    "method": "GET",
                    "path": "/message",
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
                    "method": "POST",
                    "path": "/messages/read",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "read", "from": "body", "type": "boolean", "default": true],
                        ["name": "mailbox", "from": "body", "type": "string", "default": "INBOX"],
                        ["name": "account", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/messages/flag",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "flagged", "from": "body", "type": "boolean", "default": true],
                        ["name": "mailbox", "from": "body", "type": "string", "default": "INBOX"],
                        ["name": "account", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/messages/move",
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
                    "method": "POST",
                    "path": "/messages/archive",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "mailbox", "from": "body", "type": "string", "default": "INBOX"],
                        ["name": "account", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/messages/delete",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "mailbox", "from": "body", "type": "string", "default": "INBOX"],
                        ["name": "account", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/compose",
                    "params": [
                        ["name": "to", "from": "body", "type": "string", "required": true],
                        ["name": "subject", "from": "body", "type": "string", "required": true],
                        ["name": "body", "from": "body", "type": "string", "required": true],
                        ["name": "cc", "from": "body", "type": "string"],
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

// GET /accounts
app.get("accounts") { req -> Response in
    let accounts = mailAPI.getAccounts()
    return try responseJSON(["ok": true, "result": accounts])
}

// GET /mailboxes
app.get("mailboxes") { req -> Response in
    let account = req.query[String.self, at: "account"]
    let mailboxes = mailAPI.getMailboxes(account: account)
    return try responseJSON(["ok": true, "result": mailboxes])
}

// GET /messages
app.get("messages") { req -> Response in
    let mailbox = req.query[String.self, at: "mailbox"] ?? "INBOX"
    let account = req.query[String.self, at: "account"]
    let unread = req.query[Bool.self, at: "unread"] ?? false
    let flagged = req.query[Bool.self, at: "flagged"] ?? false
    let search = req.query[String.self, at: "search"]
    let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)
    let offset = req.query[Int.self, at: "offset"] ?? 0

    let messages = mailAPI.getMessages(
        mailbox: mailbox, account: account, unread: unread, flagged: flagged,
        search: search, limit: limit, offset: offset)

    return try responseJSON(["ok": true, "result": messages])
}

// GET /message
app.get("message") { req -> Response in
    guard let id = req.query[String.self, at: "id"] else {
        throw Abort(.badRequest, reason: "'id' parameter is required")
    }

    let mailbox = req.query[String.self, at: "mailbox"] ?? "INBOX"
    let account = req.query[String.self, at: "account"]
    let includeSource = req.query[Bool.self, at: "includeSource"] ?? false

    let message = mailAPI.getMessage(
        id: id, mailbox: mailbox, account: account, includeSource: includeSource)

    return try responseJSON(["ok": true, "result": message as Any])
}

// POST /messages/read
app.post("messages", "read") { req async throws -> Response in
    struct SetReadStatusRequest: Content {
        let ids: [String]
        let read: Bool?
        let mailbox: String?
        let account: String?
    }

    let body = try req.content.decode(SetReadStatusRequest.self)
    let updated = mailAPI.setReadStatus(
        ids: body.ids, read: body.read ?? true,
        mailbox: body.mailbox ?? "INBOX", account: body.account)

    return try responseJSON(["ok": true, "result": ["updated": updated]])
}

// POST /messages/flag
app.post("messages", "flag") { req async throws -> Response in
    struct SetFlaggedStatusRequest: Content {
        let ids: [String]
        let flagged: Bool?
        let mailbox: String?
        let account: String?
    }

    let body = try req.content.decode(SetFlaggedStatusRequest.self)
    let updated = mailAPI.setFlaggedStatus(
        ids: body.ids, flagged: body.flagged ?? true,
        mailbox: body.mailbox ?? "INBOX", account: body.account)

    return try responseJSON(["ok": true, "result": ["updated": updated]])
}

// POST /messages/move
app.post("messages", "move") { req async throws -> Response in
    struct MoveMessagesRequest: Content {
        let ids: [String]
        let mailbox: String
        let account: String?
        let fromMailbox: String?
        let fromAccount: String?
    }

    let body = try req.content.decode(MoveMessagesRequest.self)
    let result = mailAPI.moveMessages(
        ids: body.ids, toMailbox: body.mailbox, toAccount: body.account,
        fromMailbox: body.fromMailbox ?? "INBOX", fromAccount: body.fromAccount)

    if let error = result.error {
        return try responseJSON(["ok": false, "error": error])
    }

    return try responseJSON(["ok": true, "result": ["moved": result.moved]])
}

// POST /messages/archive
app.post("messages", "archive") { req async throws -> Response in
    struct ArchiveMessagesRequest: Content {
        let ids: [String]
        let mailbox: String?
        let account: String?
    }

    let body = try req.content.decode(ArchiveMessagesRequest.self)
    let result = mailAPI.archiveMessages(
        ids: body.ids, mailbox: body.mailbox ?? "INBOX", account: body.account)

    if let error = result.error {
        return try responseJSON(["ok": false, "error": error])
    }

    return try responseJSON(["ok": true, "result": ["archived": result.archived]])
}

// POST /messages/delete
app.post("messages", "delete") { req async throws -> Response in
    struct DeleteMessagesRequest: Content {
        let ids: [String]
        let mailbox: String?
        let account: String?
    }

    let body = try req.content.decode(DeleteMessagesRequest.self)
    let deleted = mailAPI.deleteMessages(
        ids: body.ids, mailbox: body.mailbox ?? "INBOX", account: body.account)

    return try responseJSON(["ok": true, "result": ["deleted": deleted]])
}

// POST /compose
app.post("compose") { req async throws -> Response in
    struct ComposeMessageRequest: Content {
        let to: String
        let subject: String
        let body: String
        let cc: String?
    }

    let body = try req.content.decode(ComposeMessageRequest.self)
    let result = mailAPI.composeMessage(
        to: body.to, subject: body.subject, body: body.body, cc: body.cc)

    if let error = result.error {
        return try responseJSON(["ok": false, "error": error])
    }

    return try responseJSON(["ok": true, "result": ["sent": result.sent]])
}

let port = Int(Environment.get("MAIL_BRIDGE_PORT") ?? "7333") ?? 7333
app.http.server.configuration.hostname = "0.0.0.0"
app.http.server.configuration.port = port

logger.notice("Listening on http://localhost:\(port)")
try app.run()

func responseJSON(_ value: Any) throws -> Response {
    let data = try JSONSerialization.data(withJSONObject: value)
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    return Response(status: .ok, headers: headers, body: .init(data: data))
}
