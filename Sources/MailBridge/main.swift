import Foundation
import Vapor

// Disable stdout buffering so print() output appears immediately in launchd logs
setvbuf(stdout, nil, _IONBF, 0)

let app = try Application(.detect())
defer { app.shutdown() }

let mailAPI = MailBridgeAPI()
let debug = Environment.get("DEBUG") == "1"

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
    let debug: Bool

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let ip =
            request.headers.first(name: "X-Forwarded-For")
            ?? request.remoteAddress?.description ?? "unknown"

        let allowed = await limiter.checkLimit(for: ip)
        if !allowed {
            if debug {
                print("[bridge] Rate limit exceeded for \(ip)")
            }
            throw Abort(.tooManyRequests, reason: "Rate limit exceeded")
        }

        return try await next.respond(to: request)
    }
}

// Logging middleware
struct LoggingMiddleware: AsyncMiddleware {
    let debug: Bool

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let start = Date()

        if debug {
            var logLine = "[bridge] \(request.method) \(request.url.path)"
            if let query = request.url.query, !query.isEmpty {
                logLine += "?\(query)"
            }
            print(logLine)
        }

        let response = try await next.respond(to: request)
        let duration = Date().timeIntervalSince(start) * 1000

        if debug {
            print("[bridge] → \(response.status.code) (\(Int(duration))ms)")
        }

        return response
    }
}

let rateLimit = Int(Environment.get("RATE_LIMIT_PER_SECOND") ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)
app.middleware.use(RateLimitMiddleware(limiter: rateLimiter, debug: debug))
app.middleware.use(LoggingMiddleware(debug: debug))

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

print("mail-bridge listening on http://localhost:\(port)\(debug ? " (debug)" : "")")
try app.run()

func responseJSON(_ value: Any) throws -> Response {
    let data = try JSONSerialization.data(withJSONObject: value)
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    return Response(status: .ok, headers: headers, body: .init(data: data))
}
