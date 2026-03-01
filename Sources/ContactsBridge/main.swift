import Contacts
import OSLog
import Vapor
import BridgeCore

let logger = os.Logger(subsystem: "com.user.bridge", category: "contacts")

let app = try Application(.detect())
defer { app.shutdown() }

// Suppress Vapor's verbose request logging - we have our own middleware
app.logger.logLevel = .notice

let contactsAPI = ContactsAPI()

let rateLimit = Int(Environment.get("RATE_LIMIT_PER_SECOND") ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)
app.middleware.use(RateLimitMiddleware(limiter: rateLimiter, log: logger))
app.middleware.use(LoggingMiddleware(log: logger))
app.middleware.use(FormatMiddleware())

// Help endpoint
app.get("help") { req -> Response in
    let markdown = """
        # Contacts Bridge API

        HTTP bridge to Apple Contacts (CNContact).

        ## Response format

        All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

        ## Contact identifiers

        Contact `id` values are stable Apple Contacts identifiers (UUID strings). They persist across app restarts and syncs.

        ## Endpoints

        ### GET /contacts
        List contacts. Returns a summary for each contact.
        - `search` — filter by name (uses Apple's built-in name matching)
        - `limit` (default: 100)

        Returns: `id`, `name`, `firstName`, `lastName`, `organization`, `jobTitle`, `emails` (array of {label, value}), `phones` (array of {label, value})

        ### GET /contact
        Get full details for a single contact.
        - `id` (required) — the contact identifier

        Returns: all fields from /contacts plus `nickname`, `department`, `note`, `birthday`, `addresses` (array of {label, street, city, state, postalCode, country})

        ### GET /search
        Search contacts by email or phone. At least one parameter is required.
        - `email` — search by email address (partial match supported)
        - `phone` — search by phone number (partial match supported)

        Returns: same fields as /contacts

        ### POST /contacts
        Create a new contact.
        - `firstName` (required)
        - `lastName`
        - `organization`
        - `jobTitle`
        - `email` — added with "work" label
        - `phone` — added with "mobile" label

        Returns: `{"id": "..."}` with the new contact's identifier.

        ### GET /health
        Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

        ### GET /schema
        Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
        """
    return try responseJSON(["ok": true, "result": ["help": markdown]])
}

// Health check
app.get("health") { req -> Response in
    var result = contactsAPI.checkHealth()
    result["app"] = "contacts-bridge"
    return try responseJSON(["ok": true, "result": result])
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

logger.notice("Listening on http://localhost:\(port)")
try app.run()

