import Contacts
import Vapor

// Disable stdout buffering so print() output appears immediately in launchd logs
setvbuf(stdout, nil, _IONBF, 0)

let app = try Application(.detect())
defer { app.shutdown() }

let debug = Environment.get("DEBUG") == "1"

// Suppress Vapor's verbose request logging - we have our own middleware
app.logger.logLevel = .notice

let contactsAPI = ContactsAPI()

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
            "app": "contacts-bridge",
        ],
    ]
    return try responseJSON(response)
}

// Schema endpoint
app.get("schema") { req -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "contacts-bridge",
            "endpoints": [
                [
                    "method": "GET",
                    "path": "/contacts",
                    "params": [
                        ["name": "search", "from": "query", "type": "string"],
                        ["name": "limit", "from": "query", "type": "number", "default": 100],
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/contact",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/search",
                    "params": [
                        ["name": "email", "from": "query", "type": "string"],
                        ["name": "phone", "from": "query", "type": "string"],
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/contacts",
                    "params": [
                        ["name": "firstName", "from": "body", "type": "string", "required": true],
                        ["name": "lastName", "from": "body", "type": "string"],
                        ["name": "organization", "from": "body", "type": "string"],
                        ["name": "jobTitle", "from": "body", "type": "string"],
                        ["name": "email", "from": "body", "type": "string"],
                        ["name": "phone", "from": "body", "type": "string"],
                    ],
                ],
            ],
        ],
    ]
    return try responseJSON(schema)
}

// GET /contacts
app.get("contacts") { req async throws -> Response in
    let search = req.query[String.self, at: "search"]
    let limit = req.query[Int.self, at: "limit"] ?? 100

    let contacts = try await contactsAPI.getContacts(search: search, limit: limit)
    return try responseJSON(["ok": true, "result": contacts])
}

// GET /contact
app.get("contact") { req async throws -> Response in
    guard let id = req.query[String.self, at: "id"] else {
        throw Abort(.badRequest, reason: "'id' parameter is required")
    }

    let contact = try await contactsAPI.getContact(id: id)
    return try responseJSON(["ok": true, "result": contact as Any])
}

// GET /search
app.get("search") { req async throws -> Response in
    let email = req.query[String.self, at: "email"]
    let phone = req.query[String.self, at: "phone"]

    guard email != nil || phone != nil else {
        throw Abort(.badRequest, reason: "Either 'email' or 'phone' parameter is required")
    }

    let contacts = try await contactsAPI.searchContacts(email: email, phone: phone)
    return try responseJSON(["ok": true, "result": contacts])
}

// POST /contacts
app.post("contacts") { req async throws -> Response in
    struct CreateContactRequest: Content {
        let firstName: String
        let lastName: String?
        let organization: String?
        let jobTitle: String?
        let email: String?
        let phone: String?
    }

    let body = try req.content.decode(CreateContactRequest.self)

    let contactId = try await contactsAPI.createContact(
        firstName: body.firstName,
        lastName: body.lastName,
        organization: body.organization,
        jobTitle: body.jobTitle,
        email: body.email,
        phone: body.phone
    )

    return try responseJSON(["ok": true, "result": ["id": contactId]])
}

let port = Int(Environment.get("CONTACTS_BRIDGE_PORT") ?? "7335") ?? 7335
app.http.server.configuration.hostname = "0.0.0.0"
app.http.server.configuration.port = port

print("contacts-bridge listening on http://localhost:\(port)\(debug ? " (debug)" : "")")
try app.run()

func responseJSON(_ value: Any) throws -> Response {
    let data = try JSONSerialization.data(withJSONObject: value)
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    return Response(status: .ok, headers: headers, body: .init(data: data))
}
