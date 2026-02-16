import Foundation
import OSLog
import Vapor

let logger = os.Logger(subsystem: "com.user.bridge", category: "things")

let app = try Application(.detect())
defer { app.shutdown() }

// Suppress Vapor's verbose request logging - we have our own middleware
app.logger.logLevel = .notice

let thingsAPI = ThingsAPI()

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
        # Things 3 Bridge API

        HTTP bridge to Things 3. All responses return `{"ok": true, "result": ...}` on success.

        Things 3 must be running for this bridge to work.

        ## Identifiers

        Things uses stable string IDs for todos, projects, areas, and lists. Built-in list IDs have fixed names like `TMTodayListSource`, `TMInboxListSource`, `TMUpcomingListSource`, etc.

        ## Status values

        Todo status is one of: `open`, `completed`, `cancelled`.

        ## Endpoints

        ### GET /lists
        List all built-in lists (Inbox, Today, Anytime, etc.) and areas. Returns `id` and `name`.

        ### GET /areas
        List user-defined areas. Returns `id` and `name`.

        ### GET /projects
        List all open projects.
        - `areaId` — filter by area

        Returns: `id`, `name`, `notes`, `area` ({id, name} or null)

        ### GET /todos
        List todos with optional filters. Only one of `listId`, `areaId`, `projectId` should be provided.
        - `listId` — filter by built-in list (e.g. `TMTodayListSource`)
        - `areaId` — filter by area
        - `projectId` — filter by project
        - `status` (default: "open") — filter by status, or "any" for all
        - `limit` (default: 50, max: 200)

        Returns: `id`, `name`, `notes`, `status`, `dueDate`, `activationDate`, `tags`, `project` ({id, name} or null), `area` ({id, name} or null)

        ### GET /todo
        Get a single todo with full details.
        - `id` (required)

        ### POST /todos
        Create a new todo.
        - `name` (required) — todo title
        - `notes` — additional notes
        - `dueDate` — ISO date string (YYYY-MM-DD)
        - `listId` — move to this list after creation
        - `projectId` — move to this project after creation

        Returns: `{"id": "..."}` with the new todo's identifier.

        ### POST /todos/status
        Set status on one or more todos.
        - `ids` (required) — array of todo ID strings
        - `status` (required) — "completed", "open", or "cancelled"

        Returns: `{"updated": N, "newRecurringInstances": [...]}`. When completing a repeating todo, Things creates a new open instance — these are returned in `newRecurringInstances`.

        ### POST /todos/delete
        Delete todos by ID.
        - `ids` (required) — array of todo ID strings

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
            "app": "things-bridge",
        ],
    ]
    return try responseJSON(response)
}

// Schema endpoint
app.get("schema") { req -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "things-bridge",
            "endpoints": [
                [
                    "method": "GET",
                    "path": "/lists",
                    "params": [],
                ],
                [
                    "method": "GET",
                    "path": "/areas",
                    "params": [],
                ],
                [
                    "method": "GET",
                    "path": "/projects",
                    "params": [
                        ["name": "areaId", "from": "query", "type": "string"]
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/todos",
                    "params": [
                        ["name": "listId", "from": "query", "type": "string"],
                        ["name": "areaId", "from": "query", "type": "string"],
                        ["name": "projectId", "from": "query", "type": "string"],
                        ["name": "status", "from": "query", "type": "string", "default": "open"],
                        ["name": "limit", "from": "query", "type": "number", "default": 50],
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/todo",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/todos",
                    "params": [
                        ["name": "name", "from": "body", "type": "string", "required": true],
                        ["name": "notes", "from": "body", "type": "string"],
                        ["name": "dueDate", "from": "body", "type": "string"],
                        ["name": "listId", "from": "body", "type": "string"],
                        ["name": "projectId", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/todos/status",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        [
                            "name": "status", "from": "body", "type": "string",
                            "required": true,
                        ],
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/todos/delete",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true]
                    ],
                ],
            ],
        ],
    ]
    return try responseJSON(schema)
}

// GET /lists
app.get("lists") { req throws -> Response in
    let lists = try thingsAPI.getLists()
    return try responseJSON(["ok": true, "result": lists])
}

// GET /areas
app.get("areas") { req throws -> Response in
    let areas = try thingsAPI.getAreas()
    return try responseJSON(["ok": true, "result": areas])
}

// GET /projects
app.get("projects") { req throws -> Response in
    let areaId = req.query[String.self, at: "areaId"]
    let projects = try thingsAPI.getProjects(areaId: areaId)
    return try responseJSON(["ok": true, "result": projects])
}

// GET /todos
app.get("todos") { req throws -> Response in
    let listId = req.query[String.self, at: "listId"]
    let areaId = req.query[String.self, at: "areaId"]
    let projectId = req.query[String.self, at: "projectId"]
    let status = req.query[String.self, at: "status"] ?? "open"
    let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)

    let todos = try thingsAPI.getTodos(
        listId: listId, areaId: areaId, projectId: projectId,
        status: status, limit: limit)
    return try responseJSON(["ok": true, "result": todos])
}

// GET /todo
app.get("todo") { req throws -> Response in
    guard let id = req.query[String.self, at: "id"] else {
        throw Abort(.badRequest, reason: "'id' parameter is required")
    }
    let todo = try thingsAPI.getTodo(id: id)
    return try responseJSON(["ok": true, "result": todo as Any])
}

// POST /todos
app.post("todos") { req throws -> Response in
    struct CreateTodoRequest: Content {
        let name: String
        let notes: String?
        let dueDate: String?
        let listId: String?
        let projectId: String?
    }

    let body = try req.content.decode(CreateTodoRequest.self)
    let result = try thingsAPI.createTodo(
        name: body.name, notes: body.notes, dueDate: body.dueDate,
        listId: body.listId, projectId: body.projectId)
    return try responseJSON(["ok": true, "result": result])
}

// POST /todos/status
app.post("todos", "status") { req throws -> Response in
    struct SetStatusRequest: Content {
        let ids: [String]
        let status: String
    }

    let body = try req.content.decode(SetStatusRequest.self)
    let result = try thingsAPI.setStatus(ids: body.ids, status: body.status)
    return try responseJSON(["ok": true, "result": result])
}

// POST /todos/delete
app.post("todos", "delete") { req throws -> Response in
    struct DeleteTodosRequest: Content {
        let ids: [String]
    }

    let body = try req.content.decode(DeleteTodosRequest.self)
    let result = try thingsAPI.deleteTodos(ids: body.ids)
    return try responseJSON(["ok": true, "result": result])
}

let port = Int(Environment.get("THINGS_BRIDGE_PORT") ?? "7332") ?? 7332
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
