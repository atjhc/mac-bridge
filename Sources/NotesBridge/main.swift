import BridgeHTTP
import Hummingbird
import OSLog

let logger = Logger(subsystem: "com.user.bridge", category: "notes")

let notesAPI = NotesAPI()

let rateLimit = Int(ProcessInfo.processInfo.environment["RATE_LIMIT_PER_SECOND"] ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)

let router = Router()
router.add(middleware: BridgeRateLimitMiddleware(limiter: rateLimiter, log: logger))
router.add(middleware: BridgeLoggingMiddleware(log: logger))
router.add(middleware: BridgeFormatMiddleware())

router.get("help") { _, _ -> Response in
    let markdown = """
        # Notes Bridge API

        HTTP bridge to Apple Notes.

        ## Response format

        All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

        Notes.app must be running for this bridge to work.

        ## Identifiers

        Notes uses internal string IDs (e.g. `x-coredata://...`). These are stable as long as the note exists.

        ## Endpoints

        ### GET /accounts
        List all Notes accounts. Returns `id` and `name`.

        ### GET /folders
        List folders.
        - `account` — filter to a specific account name

        Returns: `id`, `name`, `shared`

        ### GET /notes
        List notes with optional filters.
        - `folder` — filter by folder name
        - `account` — filter by account name
        - `search` — search in plaintext content
        - `limit` (default: 50, max: 200)

        Returns: `id`, `name`, `preview` (first 200 chars), `folder`, `creationDate`, `modificationDate`, `passwordProtected`, `shared`

        ### GET /note
        Get a single note with full content.
        - `id` (required)

        Returns: `id`, `name`, `body` (HTML), `plaintext`, `folder`, `creationDate`, `modificationDate`, `passwordProtected`, `shared`

        ### POST /notes
        Create a new note.
        - `name` (required) — note title
        - `body` (required) — note body (HTML supported)
        - `folder` — target folder name
        - `account` — target account name

        Returns: `{"id": "..."}` with the new note's identifier.

        ### POST /notes/update
        Update an existing note.
        - `id` (required) — note ID
        - `name` — new title
        - `body` — new body (HTML supported)

        ### POST /notes/delete
        Delete notes by ID.
        - `ids` (required) — array of note ID strings

        ### POST /show
        Open a note in the Notes.app UI.
        - `id` (required) — note ID

        ### GET /search
        Search notes by content. Shorthand for `GET /notes?search=...`.
        - `q` (required) — search term
        - `limit` (default: 20, max: 100)

        Returns: `id`, `name`, `preview`, `folder`, `modificationDate`

        ### GET /health
        Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

        ### GET /schema
        Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
        """
    return try bridgeResponse(["ok": true, "result": ["help": markdown]])
}

router.get("health") { _, _ -> Response in
    let result = notesAPI.healthCheck()
    let isOk = (result["status"] as? String) == "ok"
    return try bridgeResponse(["ok": isOk, "result": result])
}

router.get("schema") { _, _ -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "notes-bridge",
            "endpoints": [
                ["method": "GET", "path": "/accounts", "params": []],
                [
                    "method": "GET", "path": "/folders",
                    "params": [
                        ["name": "account", "from": "query", "type": "string"]
                    ],
                ],
                [
                    "method": "GET", "path": "/notes",
                    "params": [
                        ["name": "folder", "from": "query", "type": "string"],
                        ["name": "account", "from": "query", "type": "string"],
                        ["name": "search", "from": "query", "type": "string"],
                        ["name": "limit", "from": "query", "type": "number", "default": 50],
                    ],
                ],
                [
                    "method": "GET", "path": "/note",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "POST", "path": "/notes",
                    "params": [
                        ["name": "name", "from": "body", "type": "string", "required": true],
                        ["name": "body", "from": "body", "type": "string", "required": true],
                        ["name": "folder", "from": "body", "type": "string"],
                        ["name": "account", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST", "path": "/notes/update",
                    "params": [
                        ["name": "id", "from": "body", "type": "string", "required": true],
                        ["name": "name", "from": "body", "type": "string"],
                        ["name": "body", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST", "path": "/notes/delete",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true]
                    ],
                ],
                [
                    "method": "POST", "path": "/show",
                    "params": [
                        ["name": "id", "from": "body", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "GET", "path": "/search",
                    "params": [
                        ["name": "q", "from": "query", "type": "string", "required": true],
                        ["name": "limit", "from": "query", "type": "number", "default": 20],
                    ],
                ],
                ["method": "GET", "path": "/help", "params": []],
                ["method": "GET", "path": "/health", "params": []],
            ],
        ],
    ]
    return try bridgeResponse(schema)
}

router.get("accounts") { _, _ async throws -> Response in
    let accounts = try await notesAPI.getAccounts()
    return try bridgeResponse(["ok": true, "result": accounts])
}

router.get("folders") { req, _ async throws -> Response in
    let account: String? = req.uri.queryParameters.get("account")
    let folders = try await notesAPI.getFolders(account: account)
    return try bridgeResponse(["ok": true, "result": folders])
}

router.get("notes") { req, _ async throws -> Response in
    let folder: String? = req.uri.queryParameters.get("folder")
    let account: String? = req.uri.queryParameters.get("account")
    let search: String? = req.uri.queryParameters.get("search")
    let limit = min(Int(req.uri.queryParameters.get("limit") ?? "") ?? 50, 200)

    let notes = try await notesAPI.getNotes(
        folder: folder, account: account, search: search, limit: limit)
    return try bridgeResponse(["ok": true, "result": notes])
}

router.get("note") { req, _ async throws -> Response in
    guard let id: String = req.uri.queryParameters.get("id") else {
        throw HTTPError(.badRequest, message: "'id' parameter is required")
    }
    let note = try await notesAPI.getNote(id: id)
    return try bridgeResponse(["ok": true, "result": note as Any])
}

router.post("notes") { req, ctx async throws -> Response in
    struct CreateNoteRequest: Decodable {
        let name: String
        let body: String
        let folder: String?
        let account: String?
    }

    let body = try await req.decode(as: CreateNoteRequest.self, context: ctx)
    let result = try await notesAPI.createNote(
        name: body.name, body: body.body, folder: body.folder, account: body.account)
    return try bridgeResponse(["ok": true, "result": result])
}

router.post("notes/update") { req, ctx async throws -> Response in
    struct UpdateNoteRequest: Decodable {
        let id: String
        let name: String?
        let body: String?
    }

    let body = try await req.decode(as: UpdateNoteRequest.self, context: ctx)
    let result = try await notesAPI.updateNote(id: body.id, name: body.name, body: body.body)
    return try bridgeResponse(["ok": true, "result": result])
}

router.post("notes/delete") { req, ctx async throws -> Response in
    struct DeleteNotesRequest: Decodable {
        let ids: [String]
    }

    let body = try await req.decode(as: DeleteNotesRequest.self, context: ctx)
    let result = try await notesAPI.deleteNotes(ids: body.ids)
    return try bridgeResponse(["ok": true, "result": result])
}

router.post("show") { req, ctx async throws -> Response in
    struct ShowNoteRequest: Decodable {
        let id: String
    }

    let body = try await req.decode(as: ShowNoteRequest.self, context: ctx)
    let result = try await notesAPI.showNote(id: body.id)
    return try bridgeResponse(["ok": true, "result": result])
}

router.get("search") { req, _ async throws -> Response in
    guard let q: String = req.uri.queryParameters.get("q") else {
        throw HTTPError(.badRequest, message: "'q' parameter is required")
    }
    let limit = min(Int(req.uri.queryParameters.get("limit") ?? "") ?? 20, 100)
    let results = try await notesAPI.searchNotes(query: q, limit: limit)
    return try bridgeResponse(["ok": true, "result": results])
}

let port = Int(ProcessInfo.processInfo.environment["NOTES_BRIDGE_PORT"] ?? "7336") ?? 7336
logger.notice("Listening on http://localhost:\(port)")

let app = Application(
    router: router,
    configuration: .init(address: .hostname("0.0.0.0", port: port))
)
try await app.runService()
