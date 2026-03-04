import BridgeCore
import Foundation
import OSLog
import Vapor

let logger = os.Logger(subsystem: "com.user.mac-bridge", category: "macbridge")

let app = try Application(.detect())
defer { app.shutdown() }

app.logger.logLevel = .notice

let config = Config.load()

let rateLimiter = RateLimiter(limit: config.rateLimit)
app.middleware.use(RateLimitMiddleware(limiter: rateLimiter, log: logger))
app.middleware.use(LoggingMiddleware(log: logger))
app.middleware.use(FormatMiddleware())

// --- Endpoint filter middleware ---

struct EndpointFilterMiddleware: AsyncMiddleware {
    let policy: EndpointPolicy
    let prefix: String
    let log: os.Logger

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        var path = request.url.path
        let prefixSlash = "/\(prefix)/"
        if path.hasPrefix(prefixSlash) {
            path = String(path.dropFirst(prefixSlash.count))
        }
        guard !policy.isBlocked(path: path, method: request.method.string) else {
            log.warning("Blocked \(request.method) \(request.url.path) by endpoint policy")
            throw Abort(.forbidden, reason: "Endpoint disabled by policy")
        }
        return try await next.respond(to: request)
    }
}

// --- Helper for JXA bridge health checks ---

func buildAppHealthResult(
    _ appName: String, health: AppHealthStatus,
    notInstalled: String, notRunning: String
) -> [String: Any] {
    var result: [String: Any] = [
        "app": appName,
        "appInstalled": health.installed,
        "appRunning": health.running,
    ]
    if health.isHealthy {
        result["status"] = "ok"
    } else if !health.installed {
        result["status"] = "error"
        result["error"] = notInstalled
    } else {
        result["status"] = "error"
        result["error"] = notRunning
    }
    return result
}

// --- Bridge registration ---

struct BridgeInfo {
    let prefix: String
    let name: String
    let healthCheck: () -> [String: Any]
}

var bridges: [BridgeInfo] = []

func bridgeGroup(_ prefix: String) -> RoutesBuilder {
    let policy = config.policy(for: prefix)
    return app.grouped(PathComponent(stringLiteral: prefix)).grouped(
        EndpointFilterMiddleware(policy: policy, prefix: prefix, log: logger))
}

if config.isEnabled("calendar") {
    let calendarAPI = CalendarAPI()
    registerCalendarRoutes(on: bridgeGroup("calendar"), api: calendarAPI)
    bridges.append(BridgeInfo(prefix: "calendar", name: "Calendar") { calendarAPI.checkHealth() })
}

if config.isEnabled("contacts") {
    let contactsAPI = ContactsAPI()
    registerContactsRoutes(on: bridgeGroup("contacts"), api: contactsAPI)
    bridges.append(BridgeInfo(prefix: "contacts", name: "Contacts") { contactsAPI.checkHealth() })
}

if config.isEnabled("mail") {
    let mailAPI = MailBridgeAPI()
    mailAPI.archiveMailboxes = config.archiveMailboxes
    registerMailRoutes(on: bridgeGroup("mail"), api: mailAPI)
    bridges.append(BridgeInfo(prefix: "mail", name: "Mail") {
        buildAppHealthResult(
            "mail-bridge",
            health: checkAppHealth(bundleIdentifier: "com.apple.mail"),
            notInstalled: "Mail.app is not installed",
            notRunning: "Mail.app is not running")
    })
}

if config.isEnabled("things") {
    let thingsAPI = ThingsAPI()
    registerThingsRoutes(on: bridgeGroup("things"), api: thingsAPI)
    bridges.append(BridgeInfo(prefix: "things", name: "Things") {
        buildAppHealthResult(
            "things-bridge",
            health: checkAppHealth(bundleIdentifier: "com.culturedcode.ThingsMac"),
            notInstalled: "Things 3 is not installed",
            notRunning: "Things 3 is not running")
    })
}

if config.isEnabled("notes") {
    let notesAPI = NotesAPI()
    registerNotesRoutes(on: bridgeGroup("notes"), api: notesAPI)
    bridges.append(BridgeInfo(prefix: "notes", name: "Notes") {
        buildAppHealthResult(
            "notes-bridge",
            health: checkAppHealth(bundleIdentifier: "com.apple.Notes"),
            notInstalled: "Notes.app is not installed",
            notRunning: "Notes.app is not running")
    })
}

if config.isEnabled("nnw") {
    let nnwAPI = NetNewsWireAPI()
    registerNetNewsWireRoutes(on: bridgeGroup("nnw"), api: nnwAPI)
    bridges.append(BridgeInfo(prefix: "nnw", name: "NetNewsWire") {
        buildAppHealthResult(
            "nnw-bridge",
            health: checkAppHealth(bundleIdentifier: "com.ranchero.NetNewsWire-Evergreen"),
            notInstalled: "NetNewsWire is not installed",
            notRunning: "NetNewsWire is not running")
    })
}

if config.isEnabled("reminders") {
    let remindersAPI = RemindersAPI()
    registerRemindersRoutes(on: bridgeGroup("reminders"), api: remindersAPI)
    bridges.append(BridgeInfo(prefix: "reminders", name: "Reminders") {
        buildAppHealthResult(
            "reminders-bridge",
            health: checkAppHealth(bundleIdentifier: "com.apple.reminders"),
            notInstalled: "Reminders is not installed",
            notRunning: "Reminders is not running")
    })
}

if config.isEnabled("messages") {
    let messagesAPI = MessagesAPI()
    registerMessagesRoutes(on: bridgeGroup("messages"), api: messagesAPI)
    bridges.append(BridgeInfo(prefix: "messages", name: "Messages") {
        buildAppHealthResult(
            "messages-bridge",
            health: checkAppHealth(bundleIdentifier: "com.apple.MobileSMS"),
            notInstalled: "Messages is not installed",
            notRunning: "Messages is not running")
    })
}

if config.isEnabled("shortcuts") {
    let shortcutsAPI = ShortcutsAPI()
    registerShortcutsRoutes(on: bridgeGroup("shortcuts"), api: shortcutsAPI)
    bridges.append(BridgeInfo(prefix: "shortcuts", name: "Shortcuts") {
        let available = FileManager.default.isExecutableFile(atPath: "/usr/bin/shortcuts")
        return [
            "app": "shortcuts-bridge",
            "status": available ? "ok" : "error",
        ]
    })
}

if !config.disabled.isEmpty {
    logger.notice("Disabled bridges: \(config.disabled.sorted().joined(separator: ", "))")
}

app.get { req -> Response in
    var bridgeResults: [[String: Any]] = []
    for bridge in bridges {
        let health = bridge.healthCheck()
        let status = health["status"] as? String ?? "unknown"
        bridgeResults.append([
            "name": bridge.name,
            "prefix": "/\(bridge.prefix)",
            "status": status,
            "help": "/\(bridge.prefix)/help",
        ])
    }
    return try responseJSON(["ok": true, "result": bridgeResults])
}

app.get("health") { req -> Response in
    var bridgeStatuses: [[String: Any]] = []
    var allHealthy = true
    for bridge in bridges {
        let health = bridge.healthCheck()
        let status = health["status"] as? String ?? "unknown"
        if status != "ok" { allHealthy = false }
        bridgeStatuses.append([
            "name": bridge.name,
            "prefix": "/\(bridge.prefix)",
            "status": status,
        ])
    }
    let result: [String: Any] = [
        "app": "macbridge",
        "status": allHealthy ? "ok" : "degraded",
        "bridges": bridgeStatuses,
    ]
    return try responseJSON(["ok": true, "result": result])
}

app.get("help") { req -> Response in
    let markdown = """
        # MacBridge API

        Unified HTTP bridge to macOS native applications. All bridges are available under a single server.

        ## Response format

        All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

        ## Bridges

        | Prefix | App | Help |
        |--------|-----|------|
        | `/calendar` | Calendar (EventKit) | [/calendar/help](/calendar/help) |
        | `/contacts` | Contacts (CNContact) | [/contacts/help](/contacts/help) |
        | `/mail` | Mail (ScriptingBridge) | [/mail/help](/mail/help) |
        | `/things` | Things 3 | [/things/help](/things/help) |
        | `/notes` | Notes | [/notes/help](/notes/help) |
        | `/nnw` | NetNewsWire | [/nnw/help](/nnw/help) |
        | `/reminders` | Reminders | [/reminders/help](/reminders/help) |
        | `/messages` | Messages | [/messages/help](/messages/help) |
        | `/shortcuts` | Shortcuts | [/shortcuts/help](/shortcuts/help) |

        ## Global endpoints

        ### GET /
        List all bridges with their current health status.

        ### GET /health
        Aggregate health check. Returns `"ok"` if all bridges are healthy, `"degraded"` otherwise.

        ### GET /help
        This help page.
        """
    return try responseJSON(["ok": true, "result": ["help": markdown]])
}

app.http.server.configuration.hostname = "0.0.0.0"
app.http.server.configuration.port = config.port

logger.notice("Listening on http://localhost:\(config.port)")
try app.run()
