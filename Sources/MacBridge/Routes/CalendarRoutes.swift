import BridgeCore
import EventKit
import Vapor

func registerCalendarRoutes(on routes: RoutesBuilder, api: CalendarAPI) {
    routes.get("help") { req -> Response in
        let markdown = """
            # Calendar Bridge API

            HTTP bridge to Apple Calendar (EventKit).

            ## Response format

            All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

            ## Date format

            All dates use ISO 8601 format: `2026-02-15T10:00:00Z`. When no timezone offset is provided, the system timezone is assumed.

            ## Endpoints

            ### GET /calendar/calendars
            List all calendars. Returns `id`, `name`, and `color` (hex) for each.

            ### GET /calendar/events
            List events in a date range, sorted chronologically.
            - `calendar` — filter by calendar name (e.g. "Home", "Work")
            - `from` (default: now) — ISO 8601 start date
            - `to` (default: 7 days from now) — ISO 8601 end date
            - `limit` (default: 100)
            - `status` — filter by status: `confirmed`, `tentative`, `canceled`, or `pending`/`none`
            - `siri` (default: false) — only show Siri-suggested events (those with messages:// or mail:// URLs)

            Returns: `id`, `summary`, `startDate`, `endDate`, `allDayEvent`, `calendar`, `location`, `description`, `status`, `attendees`, `participationStatus`, `organizer`, `url`

            ### GET /calendar/event
            Get a single event by ID.
            - `id` (required) — the event identifier from /events

            ### POST /calendar/events
            Create a new calendar event.
            - `summary` (required) — event title
            - `startDate` (required) — ISO 8601
            - `endDate` (required) — ISO 8601
            - `calendar` — calendar name; uses default calendar if omitted
            - `location`
            - `description` — event notes
            - `allDay` (default: false)

            ### POST /calendar/events/delete
            Delete events by ID.
            - `ids` (required) — array of event identifier strings

            ### GET /calendar/health
            Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

            ### GET /calendar/schema
            Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
            """
        return try responseJSON(["ok": true, "result": ["help": markdown]])
    }

    routes.get("health") { req -> Response in
        var result = api.checkHealth()
        result["app"] = "calendar-bridge"
        return try responseJSON(["ok": true, "result": result])
    }

    routes.get("schema") { req -> Response in
        let schema: [String: Any] = [
            "ok": true,
            "result": [
                "app": "calendar-bridge",
                "endpoints": [
                    [
                        "method": "GET",
                        "path": "/calendar/calendars",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/calendar/events",
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
                        "path": "/calendar/event",
                        "params": [
                            ["name": "id", "from": "query", "type": "string", "required": true]
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/calendar/events",
                        "params": [
                            ["name": "summary", "from": "body", "type": "string", "required": true],
                            [
                                "name": "startDate", "from": "body", "type": "string",
                                "required": true,
                            ],
                            [
                                "name": "endDate", "from": "body", "type": "string",
                                "required": true,
                            ],
                            ["name": "calendar", "from": "body", "type": "string"],
                            ["name": "location", "from": "body", "type": "string"],
                            ["name": "description", "from": "body", "type": "string"],
                            ["name": "allDay", "from": "body", "type": "boolean"],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/calendar/events/delete",
                        "params": [
                            ["name": "ids", "from": "body", "type": "string[]", "required": true],
                            ["name": "calendar", "from": "body", "type": "string"],
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/calendar/help",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/calendar/health",
                        "params": [] as [[String: Any]],
                    ],
                ],
            ],
        ]
        return try responseJSON(schema)
    }

    routes.get("calendars") { req async throws -> Response in
        let calendars = try await api.getCalendars()
        return try responseJSON(["ok": true, "result": calendars])
    }

    routes.get("events") { req async throws -> Response in
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

        var events = try await api.getEvents(
            calendarName: calendarName,
            from: from,
            to: to,
            limit: limit * 2,
            statusFilter: status
        )

        if siri == true {
            events = events.filter { event in
                guard let url = event["url"] as? String else { return false }
                return url.hasPrefix("messages://") || url.hasPrefix("mail://")
            }
        }

        return try responseJSON(["ok": true, "result": Array(events.prefix(limit))])
    }

    routes.get("event") { req async throws -> Response in
        guard let eventId = req.query[String.self, at: "id"] else {
            throw Abort(.badRequest, reason: "'id' parameter is required")
        }

        let event = try await api.getEvent(id: eventId)
        return try responseJSON(["ok": true, "result": event as Any])
    }

    routes.post("events") { req async throws -> Response in
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

        let eventId = try await api.createEvent(
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

    routes.post("events", "delete") { req async throws -> Response in
        struct DeleteEventsRequest: Content {
            let ids: [String]
            let calendar: String?
        }

        let body = try req.content.decode(DeleteEventsRequest.self)
        let deleted = try await api.deleteEvents(ids: body.ids)

        return try responseJSON(["ok": true, "result": ["deleted": deleted]])
    }
}
