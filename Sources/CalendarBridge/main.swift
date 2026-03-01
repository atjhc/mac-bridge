import EventKit
import OSLog
import Vapor
import BridgeCore

let logger = os.Logger(subsystem: "com.user.bridge", category: "calendar")

let app = try Application(.detect())
defer { app.shutdown() }

// Suppress Vapor's verbose request logging - we have our own middleware
app.logger.logLevel = .notice

let calendarAPI = CalendarAPI()

let rateLimit = Int(Environment.get("RATE_LIMIT_PER_SECOND") ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)
app.middleware.use(RateLimitMiddleware(limiter: rateLimiter, log: logger))
app.middleware.use(LoggingMiddleware(log: logger))
app.middleware.use(FormatMiddleware())

// Help endpoint
app.get("help") { req -> Response in
    let markdown = """
        # Calendar Bridge API

        HTTP bridge to Apple Calendar (EventKit).

        ## Response format

        All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

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
        Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

        ### GET /schema
        Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
        """
    return try responseJSON(["ok": true, "result": ["help": markdown]])
}

// Health check
app.get("health") { req -> Response in
    var result = calendarAPI.checkHealth()
    result["app"] = "calendar-bridge"
    return try responseJSON(["ok": true, "result": result])
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

