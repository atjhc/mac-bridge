import BridgeCore
import EventKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.mac-bridge", category: "calendar")

class CalendarAPI {
    private let eventStore = EKEventStore()
    private var hasAccess = false

    init() {
        Task { await requestAccess() }
    }

    private func requestAccess() async {
        do {
            hasAccess = try await eventStore.requestFullAccessToEvents()
            if hasAccess {
                let count = eventStore.calendars(for: .event).count
                log.info("Access granted, \(count) calendars visible")
            } else {
                log.warning("Access denied")
            }
        } catch {
            log.error("Failed to request access: \(error)")
        }
    }

    // MARK: - Health

    func healthCheck() -> [String: Any] {
        buildHealthResult(
            app: "calendar-bridge",
            status: hasAccess ? "ok" : "error",
            details: ["hasAccess": hasAccess]
        )
    }

    private func ensureAccess() throws {
        guard hasAccess else {
            throw NSError(
                domain: "CalendarBridge", code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Calendar access not granted"])
        }
    }

    func getCalendars() async throws -> [[String: Any]] {
        try ensureAccess()

        let calendars = eventStore.calendars(for: .event)
        return calendars.map { calendar in
            [
                "id": calendar.calendarIdentifier,
                "name": calendar.title,
                "color": calendar.cgColor.map { hexColor(from: $0) } ?? NSNull(),
            ]
        }
    }

    func getEvents(
        calendarName: String?, from: Date, to: Date, limit: Int, offset: Int,
        statusFilter: String? = nil
    ) async throws -> [[String: Any]] {
        try ensureAccess()

        let calendars: [EKCalendar]
        if let calendarName = calendarName {
            calendars = eventStore.calendars(for: .event).filter { $0.title == calendarName }
        } else {
            calendars = eventStore.calendars(for: .event)
        }

        let predicate = eventStore.predicateForEvents(
            withStart: from, end: to, calendars: calendars)

        var events = eventStore.events(matching: predicate)

        // Filter by status if specified
        if let statusFilter = statusFilter {
            events = events.filter { event in
                switch statusFilter.lowercased() {
                case "pending", "inbox", "none":
                    return event.status == .none
                case "confirmed":
                    return event.status == .confirmed
                case "tentative":
                    return event.status == .tentative
                case "canceled":
                    return event.status == .canceled
                default:
                    return true
                }
            }
        }

        return Array(events.dropFirst(offset).prefix(limit).map(eventToDict))
    }

    func getEvent(id: String) async throws -> [String: Any]? {
        try ensureAccess()

        guard let event = eventStore.event(withIdentifier: id) else { return nil }

        return eventToDict(event)
    }

    func createEvent(
        title: String, startDate: Date, endDate: Date, calendarName: String?,
        location: String?, notes: String?, isAllDay: Bool
    ) async throws -> String {
        try ensureAccess()

        let calendar: EKCalendar
        if let calendarName = calendarName {
            guard
                let found = eventStore.calendars(for: .event).first(where: {
                    $0.title == calendarName
                })
            else {
                throw NSError(
                    domain: "CalendarBridge", code: 404,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Calendar '\(calendarName)' not found"
                    ])
            }
            calendar = found
        } else {
            guard let defaultCalendar = eventStore.defaultCalendarForNewEvents else {
                throw NSError(
                    domain: "CalendarBridge", code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "No default calendar available"])
            }
            calendar = defaultCalendar
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay
        event.location = location
        event.notes = notes

        try eventStore.save(event, span: .thisEvent)

        return event.eventIdentifier
    }

    func updateEvent(
        id: String, title: String?, startDate: Date?, endDate: Date?, location: String?,
        notes: String?, isAllDay: Bool?, calendarName: String?, span: String?
    ) async throws -> [String: Any] {
        try ensureAccess()

        guard let event = eventStore.event(withIdentifier: id) else {
            throw NSError(
                domain: "CalendarBridge", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Event not found"])
        }

        if let title { event.title = title }
        if let startDate { event.startDate = startDate }
        if let endDate { event.endDate = endDate }
        if let location { event.location = location }
        if let notes { event.notes = notes }
        if let isAllDay { event.isAllDay = isAllDay }

        if let calendarName {
            guard
                let cal = eventStore.calendars(for: .event).first(where: {
                    $0.title == calendarName
                })
            else {
                throw NSError(
                    domain: "CalendarBridge", code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar '\(calendarName)' not found"])
            }
            event.calendar = cal
        }

        let ekSpan: EKSpan = span == "future" ? .futureEvents : .thisEvent
        try eventStore.save(event, span: ekSpan)
        return ["updated": true, "id": event.eventIdentifier as Any]
    }

    func setRecurrence(
        eventId: String, frequency: String, interval: Int, endDate: Date?, count: Int?
    ) async throws -> [String: Any] {
        try ensureAccess()

        guard let event = eventStore.event(withIdentifier: eventId) else {
            throw NSError(
                domain: "CalendarBridge", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Event not found"])
        }

        let freq: EKRecurrenceFrequency
        switch frequency.lowercased() {
        case "daily": freq = .daily
        case "weekly": freq = .weekly
        case "monthly": freq = .monthly
        case "yearly": freq = .yearly
        default:
            throw NSError(
                domain: "CalendarBridge", code: 400,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid frequency. Use: daily, weekly, monthly, yearly"
                ])
        }

        let end: EKRecurrenceEnd?
        if let endDate {
            end = EKRecurrenceEnd(end: endDate)
        } else if let count {
            end = EKRecurrenceEnd(occurrenceCount: count)
        } else {
            end = nil
        }

        let rule = EKRecurrenceRule(
            recurrenceWith: freq, interval: interval, end: end)
        event.recurrenceRules = [rule]
        try eventStore.save(event, span: .futureEvents)
        return ["set": true]
    }

    func removeRecurrence(eventId: String) async throws -> [String: Any] {
        try ensureAccess()

        guard let event = eventStore.event(withIdentifier: eventId) else {
            throw NSError(
                domain: "CalendarBridge", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Event not found"])
        }

        event.recurrenceRules = nil
        try eventStore.save(event, span: .futureEvents)
        return ["removed": true]
    }

    func addAlarm(eventId: String, offset: TimeInterval) async throws -> [String: Any] {
        try ensureAccess()

        guard let event = eventStore.event(withIdentifier: eventId) else {
            throw NSError(
                domain: "CalendarBridge", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Event not found"])
        }

        let alarm = EKAlarm(relativeOffset: offset)
        event.addAlarm(alarm)
        try eventStore.save(event, span: .thisEvent)
        return ["added": true]
    }

    func removeAlarms(eventId: String) async throws -> [String: Any] {
        try ensureAccess()

        guard let event = eventStore.event(withIdentifier: eventId) else {
            throw NSError(
                domain: "CalendarBridge", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Event not found"])
        }

        if let alarms = event.alarms {
            for alarm in alarms { event.removeAlarm(alarm) }
        }
        try eventStore.save(event, span: .thisEvent)
        return ["removed": true]
    }

    func deleteEvents(ids: [String]) async throws -> Int {
        try ensureAccess()

        var deleted = 0
        for id in ids {
            guard let event = eventStore.event(withIdentifier: id) else { continue }

            do {
                try eventStore.remove(event, span: .thisEvent)
                deleted += 1
            } catch {
                log.error("Failed to delete event \(id): \(error)")
            }
        }

        return deleted
    }

    private func eventToDict(_ event: EKEvent) -> [String: Any] {
        let iso8601 = ISO8601DateFormatter()

        let statusString: String
        switch event.status {
        case .none:
            statusString = "none"
        case .confirmed:
            statusString = "confirmed"
        case .tentative:
            statusString = "tentative"
        case .canceled:
            statusString = "canceled"
        @unknown default:
            statusString = "unknown"
        }

        // Get attendees and current user's participation status
        var attendeesArray: [[String: Any]] = []
        var currentUserStatus: String = "none"

        if let attendees = event.attendees {
            for attendee in attendees {
                let participationString: String
                switch attendee.participantStatus {
                case .unknown:
                    participationString = "unknown"
                case .pending:
                    participationString = "pending"
                case .accepted:
                    participationString = "accepted"
                case .declined:
                    participationString = "declined"
                case .tentative:
                    participationString = "tentative"
                case .delegated:
                    participationString = "delegated"
                case .completed:
                    participationString = "completed"
                case .inProcess:
                    participationString = "inProcess"
                @unknown default:
                    participationString = "unknown"
                }

                attendeesArray.append([
                    "name": attendee.name ?? "",
                    "email":
                        attendee.url.absoluteString.replacingOccurrences(
                            of: "mailto:", with: ""),
                    "isCurrentUser": attendee.isCurrentUser,
                    "participationStatus": participationString,
                ])

                if attendee.isCurrentUser {
                    currentUserStatus = participationString
                }
            }
        }

        var alarmsArray: [[String: Any]] = []
        if let alarms = event.alarms {
            for alarm in alarms {
                var a: [String: Any] = ["offset": alarm.relativeOffset]
                if let absoluteDate = alarm.absoluteDate {
                    a["absoluteDate"] = iso8601.string(from: absoluteDate)
                }
                alarmsArray.append(a)
            }
        }

        var recurrenceArray: [[String: Any]] = []
        if let rules = event.recurrenceRules {
            for rule in rules {
                let freqStr: String
                switch rule.frequency {
                case .daily: freqStr = "daily"
                case .weekly: freqStr = "weekly"
                case .monthly: freqStr = "monthly"
                case .yearly: freqStr = "yearly"
                @unknown default: freqStr = "unknown"
                }
                var r: [String: Any] = [
                    "frequency": freqStr,
                    "interval": rule.interval,
                ]
                if let end = rule.recurrenceEnd {
                    if let endDate = end.endDate {
                        r["endDate"] = iso8601.string(from: endDate)
                    }
                    if end.occurrenceCount > 0 {
                        r["occurrenceCount"] = end.occurrenceCount
                    }
                }
                recurrenceArray.append(r)
            }
        }

        return [
            "id": event.eventIdentifier as Any,
            "summary": event.title ?? "",
            "location": event.location ?? NSNull(),
            "startDate": iso8601.string(from: event.startDate),
            "endDate": iso8601.string(from: event.endDate),
            "allDayEvent": event.isAllDay,
            "description": event.notes ?? NSNull(),
            "calendar": event.calendar.title,
            "calendarType": event.calendar.type.rawValue,
            "status": statusString,
            "attendees": attendeesArray,
            "participationStatus": currentUserStatus,
            "hasAttendees": event.hasAttendees,
            "organizer": event.organizer?.name ?? NSNull(),
            "url": event.url?.absoluteString ?? NSNull(),
            "alarms": alarmsArray,
            "recurrenceRules": recurrenceArray,
            "hasRecurrenceRules": event.hasRecurrenceRules,
        ]
    }

    private func hexColor(from cgColor: CGColor) -> String {
        guard let components = cgColor.components, components.count >= 3 else { return "#000000" }

        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)

        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
