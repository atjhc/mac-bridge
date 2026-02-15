import EventKit
import OSLog
import Vapor

let logger = os.Logger(subsystem: "com.user.bridge", category: "calendar")

let app = try Application(.detect())
defer { app.shutdown() }

// Suppress Vapor's verbose request logging - we have our own middleware
app.logger.logLevel = .notice

let calendarAPI = CalendarAPI()

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

let rateLimit = Int(Environment.get("RATE_LIMIT_PER_SECOND") ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)
app.middleware.use(RateLimitMiddleware(limiter: rateLimiter, log: logger))
app.middleware.use(LoggingMiddleware(log: logger))

// Help endpoint
app.get("help") { req -> Response in
    let markdown = """
        # Calendar Bridge API

        HTTP bridge to Apple Calendar (EventKit). All responses return `{"ok": true, "result": ...}` on success.

        ## Date format

        All dates use ISO 8601 format: `2026-02-15T10:00:00Z`. When no timezone offset is provided, the system timezone is assumed.

        ## Endpoints

        ### GET /calendars
        List all calendars. Returns `id`, `name`, and `color` (hex) for each.

        ### GET /events
        List events in a date range, sorted chronologically.
        - `calendar` — filter by calendar name (e.g. "Home", "Work")
        - `from` (default: now) — ISO 8601 start date
        - `to` (default: 7 days from now) — ISO 8601 end date
        - `limit` (default: 100)
        - `status` — filter by status: `confirmed`, `tentative`, `canceled`, or `pending`/`none`
        - `siri` (default: false) — only show Siri-suggested events (those with messages:// or mail:// URLs)

        Returns: `id`, `summary`, `startDate`, `endDate`, `allDayEvent`, `calendar`, `location`, `description`, `status`, `attendees`, `participationStatus`, `organizer`, `url`

        ### GET /event
        Get a single event by ID.
        - `id` (required) — the event identifier from /events

        ### POST /events
        Create a new calendar event.
        - `summary` (required) — event title
        - `startDate` (required) — ISO 8601
        - `endDate` (required) — ISO 8601
        - `calendar` — calendar name; uses default calendar if omitted
        - `location`
        - `description` — event notes
        - `allDay` (default: false)

        ### POST /events/delete
        Delete events by ID.
        - `ids` (required) — array of event identifier strings

        ### GET /health
        Returns `{"ok": true}` if the bridge is running.

        ### GET /schema
        Returns machine-readable endpoint definitions (JSON).
        """
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "text/markdown; charset=utf-8")
    return Response(status: .ok, headers: headers, body: .init(string: markdown))
}

// Health check
app.get("health") { req -> Response in
    let response: [String: Any] = [
        "ok": true,
        "result": [
            "status": "ok",
            "app": "calendar-bridge",
        ],
    ]
    return try responseJSON(response)
}

// Schema endpoint
app.get("schema") { req -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "calendar-bridge",
            "endpoints": [
                [
                    "method": "GET",
                    "path": "/calendars",
                    "params": [],
                ],
                [
                    "method": "GET",
                    "path": "/events",
                    "params": [
                        ["name": "calendar", "from": "query", "type": "string"],
                        ["name": "from", "from": "query", "type": "string"],
                        ["name": "to", "from": "query", "type": "string"],
                        ["name": "limit", "from": "query", "type": "number", "default": 100],
                        ["name": "status", "from": "query", "type": "string"],
                        ["name": "siri", "from": "query", "type": "boolean"],
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/event",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/events",
                    "params": [
                        ["name": "summary", "from": "body", "type": "string", "required": true],
                        ["name": "startDate", "from": "body", "type": "string", "required": true],
                        ["name": "endDate", "from": "body", "type": "string", "required": true],
                        ["name": "calendar", "from": "body", "type": "string"],
                        ["name": "location", "from": "body", "type": "string"],
                        ["name": "description", "from": "body", "type": "string"],
                        ["name": "allDay", "from": "body", "type": "boolean"],
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/events/delete",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "calendar", "from": "body", "type": "string"],
                    ],
                ],
            ],
        ],
    ]
    return try responseJSON(schema)
}

// GET /calendars
app.get("calendars") { req async throws -> Response in
    let calendars = try await calendarAPI.getCalendars()
    return try responseJSON(["ok": true, "result": calendars])
}

// GET /events
app.get("events") { req async throws -> Response in
    let calendarName = req.query[String.self, at: "calendar"]
    let fromStr = req.query[String.self, at: "from"]
    let toStr = req.query[String.self, at: "to"]
    let limit = req.query[Int.self, at: "limit"] ?? 100
    let status = req.query[String.self, at: "status"]
    let siri = req.query[Bool.self, at: "siri"]

    let from = fromStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
    let to =
        toStr.flatMap { ISO8601DateFormatter().date(from: $0) }
        ?? Date(timeIntervalSinceNow: 7 * 86400)

    var events = try await calendarAPI.getEvents(
        calendarName: calendarName,
        from: from,
        to: to,
        limit: limit * 2,
        statusFilter: status
    )

    // Filter for Siri suggestions (events with messages:// or mail:// URLs)
    if siri == true {
        events = events.filter { event in
            guard let url = event["url"] as? String else { return false }
            return url.hasPrefix("messages://") || url.hasPrefix("mail://")
        }
    }

    return try responseJSON(["ok": true, "result": Array(events.prefix(limit))])
}

// GET /event
app.get("event") { req async throws -> Response in
    guard let eventId = req.query[String.self, at: "id"] else {
        throw Abort(.badRequest, reason: "'id' parameter is required")
    }

    let event = try await calendarAPI.getEvent(id: eventId)
    return try responseJSON(["ok": true, "result": event as Any])
}

// POST /events
app.post("events") { req async throws -> Response in
    struct CreateEventRequest: Content {
        let summary: String
        let startDate: String
        let endDate: String
        let calendar: String?
        let location: String?
        let description: String?
        let allDay: Bool?
    }

    let body = try req.content.decode(CreateEventRequest.self)

    guard let startDate = ISO8601DateFormatter().date(from: body.startDate),
        let endDate = ISO8601DateFormatter().date(from: body.endDate)
    else {
        throw Abort(.badRequest, reason: "Invalid date format")
    }

    let eventId = try await calendarAPI.createEvent(
        title: body.summary,
        startDate: startDate,
        endDate: endDate,
        calendarName: body.calendar,
        location: body.location,
        notes: body.description,
        isAllDay: body.allDay ?? false
    )

    return try responseJSON(["ok": true, "result": ["id": eventId]])
}

// POST /events/delete
app.post("events", "delete") { req async throws -> Response in
    struct DeleteEventsRequest: Content {
        let ids: [String]
        let calendar: String?
    }

    let body = try req.content.decode(DeleteEventsRequest.self)
    let deleted = try await calendarAPI.deleteEvents(ids: body.ids)

    return try responseJSON(["ok": true, "result": ["deleted": deleted]])
}

let port = Int(Environment.get("CALENDAR_BRIDGE_PORT") ?? "7334") ?? 7334
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
