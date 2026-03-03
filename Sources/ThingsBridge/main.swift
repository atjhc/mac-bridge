import BridgeHTTP
import Hummingbird
import OSLog

let logger = Logger(subsystem: "com.user.bridge", category: "things")

let thingsAPI = ThingsAPI()

let rateLimit = Int(ProcessInfo.processInfo.environment["RATE_LIMIT_PER_SECOND"] ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)

let router = Router()
router.add(middleware: BridgeRateLimitMiddleware(limiter: rateLimiter, log: logger))
router.add(middleware: BridgeLoggingMiddleware(log: logger))
router.add(middleware: BridgeFormatMiddleware())

router.get("help") { _, _ -> Response in
    let markdown = """
        # Things 3 Bridge API

        HTTP bridge to Things 3.

        ## Response format

        All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

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
        Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

        ### GET /schema
        Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
        """
    return try bridgeResponse(["ok": true, "result": ["help": markdown]])
}

router.get("health") { _, _ -> Response in
    let result = thingsAPI.healthCheck()
    let isOk = (result["status"] as? String) == "ok"
    return try bridgeResponse(["ok": isOk, "result": result])
}

router.get("schema") { _, _ -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "things-bridge",
            "endpoints": [
                ["method": "GET", "path": "/lists", "params": []],
                ["method": "GET", "path": "/areas", "params": []],
                [
                    "method": "GET", "path": "/projects",
                    "params": [
                        ["name": "areaId", "from": "query", "type": "string"]
                    ],
                ],
                [
                    "method": "GET", "path": "/todos",
                    "params": [
                        ["name": "listId", "from": "query", "type": "string"],
                        ["name": "areaId", "from": "query", "type": "string"],
                        ["name": "projectId", "from": "query", "type": "string"],
                        ["name": "status", "from": "query", "type": "string", "default": "open"],
                        ["name": "limit", "from": "query", "type": "number", "default": 50],
                    ],
                ],
                [
                    "method": "GET", "path": "/todo",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "POST", "path": "/todos",
                    "params": [
                        ["name": "name", "from": "body", "type": "string", "required": true],
                        ["name": "notes", "from": "body", "type": "string"],
                        ["name": "dueDate", "from": "body", "type": "string"],
                        ["name": "listId", "from": "body", "type": "string"],
                        ["name": "projectId", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST", "path": "/todos/status",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "status", "from": "body", "type": "string", "required": true],
                    ],
                ],
                [
                    "method": "POST", "path": "/todos/delete",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true]
                    ],
                ],
                ["method": "GET", "path": "/help", "params": []],
                ["method": "GET", "path": "/health", "params": []],
            ],
        ],
    ]
    return try bridgeResponse(schema)
}

router.get("lists") { _, _ async throws -> Response in
    let lists = try await thingsAPI.getLists()
    return try bridgeResponse(["ok": true, "result": lists])
}

router.get("areas") { _, _ async throws -> Response in
    let areas = try await thingsAPI.getAreas()
    return try bridgeResponse(["ok": true, "result": areas])
}

router.get("projects") { req, _ async throws -> Response in
    let areaId: String? = req.uri.queryParameters.get("areaId")
    let projects = try await thingsAPI.getProjects(areaId: areaId)
    return try bridgeResponse(["ok": true, "result": projects])
}

router.get("todos") { req, _ async throws -> Response in
    let listId: String? = req.uri.queryParameters.get("listId")
    let areaId: String? = req.uri.queryParameters.get("areaId")
    let projectId: String? = req.uri.queryParameters.get("projectId")
    let status = req.uri.queryParameters.get("status") ?? "open"
    let limit = min(Int(req.uri.queryParameters.get("limit") ?? "") ?? 50, 200)

    let todos = try await thingsAPI.getTodos(
        listId: listId, areaId: areaId, projectId: projectId,
        status: status, limit: limit)
    return try bridgeResponse(["ok": true, "result": todos])
}

router.get("todo") { req, _ async throws -> Response in
    guard let id: String = req.uri.queryParameters.get("id") else {
        throw HTTPError(.badRequest, message: "'id' parameter is required")
    }
    let todo = try await thingsAPI.getTodo(id: id)
    return try bridgeResponse(["ok": true, "result": todo as Any])
}

router.post("todos") { req, ctx async throws -> Response in
    struct CreateTodoRequest: Decodable {
        let name: String
        let notes: String?
        let dueDate: String?
        let listId: String?
        let projectId: String?
    }

    let body = try await req.decode(as: CreateTodoRequest.self, context: ctx)
    let result = try await thingsAPI.createTodo(
        name: body.name, notes: body.notes, dueDate: body.dueDate,
        listId: body.listId, projectId: body.projectId)
    return try bridgeResponse(["ok": true, "result": result])
}

router.post("todos/status") { req, ctx async throws -> Response in
    struct SetStatusRequest: Decodable {
        let ids: [String]
        let status: String
    }

    let body = try await req.decode(as: SetStatusRequest.self, context: ctx)
    let result = try await thingsAPI.setStatus(ids: body.ids, status: body.status)
    return try bridgeResponse(["ok": true, "result": result])
}

router.post("todos/delete") { req, ctx async throws -> Response in
    struct DeleteTodosRequest: Decodable {
        let ids: [String]
    }

    let body = try await req.decode(as: DeleteTodosRequest.self, context: ctx)
    let result = try await thingsAPI.deleteTodos(ids: body.ids)
    return try bridgeResponse(["ok": true, "result": result])
}

let port = Int(ProcessInfo.processInfo.environment["THINGS_BRIDGE_PORT"] ?? "7332") ?? 7332
logger.notice("Listening on http://localhost:\(port)")

let app = Application(
    router: router,
    configuration: .init(address: .hostname("0.0.0.0", port: port))
)
try await app.runService()
