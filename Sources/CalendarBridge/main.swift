import BridgeHTTP
import EventKit
import Hummingbird
import OSLog

let logger = Logger(subsystem: "com.user.bridge", category: "calendar")

let calendarAPI = CalendarAPI()

let rateLimit = Int(ProcessInfo.processInfo.environment["RATE_LIMIT_PER_SECOND"] ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)

let router = Router()
router.add(middleware: BridgeRateLimitMiddleware(limiter: rateLimiter, log: logger))
router.add(middleware: BridgeLoggingMiddleware(log: logger))
router.add(middleware: BridgeFormatMiddleware())

router.get("help") { _, _ -> Response in
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
    return try bridgeResponse(["ok": true, "result": ["help": markdown]])
}

router.get("health") { _, _ -> Response in
    let result = calendarAPI.healthCheck()
    let isOk = (result["status"] as? String) == "ok"
    return try bridgeResponse(["ok": isOk, "result": result])
}

router.get("schema") { _, _ -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "calendar-bridge",
            "endpoints": [
                ["method": "GET", "path": "/calendars", "params": []],
                [
                    "method": "GET", "path": "/events",
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
                    "method": "GET", "path": "/event",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "POST", "path": "/events",
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
                    "method": "POST", "path": "/events/delete",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "calendar", "from": "body", "type": "string"],
                    ],
                ],
                ["method": "GET", "path": "/help", "params": []],
                ["method": "GET", "path": "/health", "params": []],
            ],
        ],
    ]
    return try bridgeResponse(schema)
}

router.get("calendars") { _, _ -> Response in
    let calendars = try await calendarAPI.getCalendars()
    return try bridgeResponse(["ok": true, "result": calendars])
}

router.get("events") { req, _ -> Response in
    let calendarName: String? = req.uri.queryParameters.get("calendar")
    let fromStr: String? = req.uri.queryParameters.get("from")
    let toStr: String? = req.uri.queryParameters.get("to")
    let limit = Int(req.uri.queryParameters.get("limit") ?? "") ?? 100
    let status: String? = req.uri.queryParameters.get("status")
    let siri = req.uri.queryParameters.get("siri") == "true"

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

    if siri {
        events = events.filter { event in
            guard let url = event["url"] as? String else { return false }
            return url.hasPrefix("messages://") || url.hasPrefix("mail://")
        }
    }

    return try bridgeResponse(["ok": true, "result": Array(events.prefix(limit))])
}

router.get("event") { req, _ -> Response in
    guard let eventId: String = req.uri.queryParameters.get("id") else {
        throw HTTPError(.badRequest, message: "'id' parameter is required")
    }
    let event = try await calendarAPI.getEvent(id: eventId)
    return try bridgeResponse(["ok": true, "result": event as Any])
}

router.post("events") { req, ctx -> Response in
    struct CreateEventRequest: Decodable {
        let summary: String
        let startDate: String
        let endDate: String
        let calendar: String?
        let location: String?
        let description: String?
        let allDay: Bool?
    }

    let body = try await req.decode(as: CreateEventRequest.self, context: ctx)

    guard let startDate = ISO8601DateFormatter().date(from: body.startDate),
        let endDate = ISO8601DateFormatter().date(from: body.endDate)
    else {
        throw HTTPError(.badRequest, message: "Invalid date format")
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

    return try bridgeResponse(["ok": true, "result": ["id": eventId]])
}

router.post("events/delete") { req, ctx -> Response in
    struct DeleteEventsRequest: Decodable {
        let ids: [String]
        let calendar: String?
    }

    let body = try await req.decode(as: DeleteEventsRequest.self, context: ctx)
    let deleted = try await calendarAPI.deleteEvents(ids: body.ids)

    return try bridgeResponse(["ok": true, "result": ["deleted": deleted]])
}

let port = Int(ProcessInfo.processInfo.environment["CALENDAR_BRIDGE_PORT"] ?? "7334") ?? 7334
logger.notice("Listening on http://localhost:\(port)")

let app = Application(
    router: router,
    configuration: .init(address: .hostname("0.0.0.0", port: port))
)
try await app.runService()
