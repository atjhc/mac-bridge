import BridgeHTTP
import Contacts
import Hummingbird
import OSLog

let logger = Logger(subsystem: "com.user.bridge", category: "contacts")

let contactsAPI = ContactsAPI()

let rateLimit = Int(ProcessInfo.processInfo.environment["RATE_LIMIT_PER_SECOND"] ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)

let router = Router()
router.add(middleware: BridgeRateLimitMiddleware(limiter: rateLimiter, log: logger))
router.add(middleware: BridgeLoggingMiddleware(log: logger))
router.add(middleware: BridgeFormatMiddleware())

router.get("help") { _, _ -> Response in
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
    return try bridgeResponse(["ok": true, "result": ["help": markdown]])
}

router.get("health") { _, _ -> Response in
    let result = contactsAPI.healthCheck()
    let isOk = (result["status"] as? String) == "ok"
    return try bridgeResponse(["ok": isOk, "result": result])
}

router.get("schema") { _, _ -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "contacts-bridge",
            "endpoints": [
                [
                    "method": "GET", "path": "/contacts",
                    "params": [
                        ["name": "search", "from": "query", "type": "string"],
                        ["name": "limit", "from": "query", "type": "number", "default": 100],
                    ],
                ],
                [
                    "method": "GET", "path": "/contact",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "GET", "path": "/search",
                    "params": [
                        ["name": "email", "from": "query", "type": "string"],
                        ["name": "phone", "from": "query", "type": "string"],
                    ],
                ],
                [
                    "method": "POST", "path": "/contacts",
                    "params": [
                        ["name": "firstName", "from": "body", "type": "string", "required": true],
                        ["name": "lastName", "from": "body", "type": "string"],
                        ["name": "organization", "from": "body", "type": "string"],
                        ["name": "jobTitle", "from": "body", "type": "string"],
                        ["name": "email", "from": "body", "type": "string"],
                        ["name": "phone", "from": "body", "type": "string"],
                    ],
                ],
                ["method": "GET", "path": "/help", "params": []],
                ["method": "GET", "path": "/health", "params": []],
            ],
        ],
    ]
    return try bridgeResponse(schema)
}

router.get("contacts") { req, _ -> Response in
    let search: String? = req.uri.queryParameters.get("search")
    let limit = Int(req.uri.queryParameters.get("limit") ?? "") ?? 100
    let contacts = try await contactsAPI.getContacts(search: search, limit: limit)
    return try bridgeResponse(["ok": true, "result": contacts])
}

router.get("contact") { req, _ -> Response in
    guard let id: String = req.uri.queryParameters.get("id") else {
        throw HTTPError(.badRequest, message: "'id' parameter is required")
    }
    let contact = try await contactsAPI.getContact(id: id)
    return try bridgeResponse(["ok": true, "result": contact as Any])
}

router.get("search") { req, _ -> Response in
    let email: String? = req.uri.queryParameters.get("email")
    let phone: String? = req.uri.queryParameters.get("phone")

    guard email != nil || phone != nil else {
        throw HTTPError(.badRequest, message: "Either 'email' or 'phone' parameter is required")
    }

    let contacts = try await contactsAPI.searchContacts(email: email, phone: phone)
    return try bridgeResponse(["ok": true, "result": contacts])
}

router.post("contacts") { req, ctx -> Response in
    struct CreateContactRequest: Decodable {
        let firstName: String
        let lastName: String?
        let organization: String?
        let jobTitle: String?
        let email: String?
        let phone: String?
    }

    let body = try await req.decode(as: CreateContactRequest.self, context: ctx)
    let contactId = try await contactsAPI.createContact(
        firstName: body.firstName,
        lastName: body.lastName,
        organization: body.organization,
        jobTitle: body.jobTitle,
        email: body.email,
        phone: body.phone
    )
    return try bridgeResponse(["ok": true, "result": ["id": contactId]])
}

let port = Int(ProcessInfo.processInfo.environment["CONTACTS_BRIDGE_PORT"] ?? "7335") ?? 7335
logger.notice("Listening on http://localhost:\(port)")

let app = Application(
    router: router,
    configuration: .init(address: .hostname("0.0.0.0", port: port))
)
try await app.runService()
