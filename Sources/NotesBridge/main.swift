import Foundation
import OSLog
import Vapor
import BridgeCore

let logger = os.Logger(subsystem: "com.user.bridge", category: "notes")

let app = try Application(.detect())
defer { app.shutdown() }

app.logger.logLevel = .notice

let notesAPI = NotesAPI()

let rateLimit = Int(Environment.get("RATE_LIMIT_PER_SECOND") ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)
app.middleware.use(RateLimitMiddleware(limiter: rateLimiter, log: logger))
app.middleware.use(LoggingMiddleware(log: logger))
app.middleware.use(FormatMiddleware())

// Help endpoint
app.get("help") { req -> Response in
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
    return try responseJSON(["ok": true, "result": ["help": markdown]])
}

// Health check
app.get("health") { req -> Response in
    let health = checkAppHealth(bundleIdentifier: "com.apple.Notes")
    var result: [String: Any] = [
        "app": "notes-bridge",
        "appInstalled": health.installed,
        "appRunning": health.running,
    ]
    if health.isHealthy {
        result["status"] = "ok"
    } else if !health.installed {
        result["status"] = "error"
        result["error"] = "Notes.app is not installed"
    } else {
        result["status"] = "error"
        result["error"] = "Notes.app is not running"
    }
    return try responseJSON(["ok": true, "result": result])
}

// Schema endpoint
app.get("schema") { req -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "notes-bridge",
            "endpoints": [
                [
                    "method": "GET",
                    "path": "/accounts",
                    "params": [],
                ],
                [
                    "method": "GET",
                    "path": "/folders",
                    "params": [
                        ["name": "account", "from": "query", "type": "string"]
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/notes",
                    "params": [
                        ["name": "folder", "from": "query", "type": "string"],
                        ["name": "account", "from": "query", "type": "string"],
                        ["name": "search", "from": "query", "type": "string"],
                        ["name": "limit", "from": "query", "type": "number", "default": 50],
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/note",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/notes",
                    "params": [
                        ["name": "name", "from": "body", "type": "string", "required": true],
                        ["name": "body", "from": "body", "type": "string", "required": true],
                        ["name": "folder", "from": "body", "type": "string"],
                        ["name": "account", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/notes/update",
                    "params": [
                        ["name": "id", "from": "body", "type": "string", "required": true],
                        ["name": "name", "from": "body", "type": "string"],
                        ["name": "body", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/notes/delete",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true]
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/show",
                    "params": [
                        ["name": "id", "from": "body", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/search",
                    "params": [
                        ["name": "q", "from": "query", "type": "string", "required": true],
                        ["name": "limit", "from": "query", "type": "number", "default": 20],
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

// GET /accounts
app.get("accounts") { req throws -> Response in
    let accounts = try notesAPI.getAccounts()
    return try responseJSON(["ok": true, "result": accounts])
}

// GET /folders
app.get("folders") { req throws -> Response in
    let account = req.query[String.self, at: "account"]
    let folders = try notesAPI.getFolders(account: account)
    return try responseJSON(["ok": true, "result": folders])
}

// GET /notes
app.get("notes") { req throws -> Response in
    let folder = req.query[String.self, at: "folder"]
    let account = req.query[String.self, at: "account"]
    let search = req.query[String.self, at: "search"]
    let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)

    let notes = try notesAPI.getNotes(
        folder: folder, account: account, search: search, limit: limit)
    return try responseJSON(["ok": true, "result": notes])
}

// GET /note
app.get("note") { req throws -> Response in
    guard let id = req.query[String.self, at: "id"] else {
        throw Abort(.badRequest, reason: "'id' parameter is required")
    }
    let note = try notesAPI.getNote(id: id)
    return try responseJSON(["ok": true, "result": note as Any])
}

// POST /notes
app.post("notes") { req throws -> Response in
    struct CreateNoteRequest: Content {
        let name: String
        let body: String
        let folder: String?
        let account: String?
    }

    let body = try req.content.decode(CreateNoteRequest.self)
    let result = try notesAPI.createNote(
        name: body.name, body: body.body, folder: body.folder, account: body.account)
    return try responseJSON(["ok": true, "result": result])
}

// POST /notes/update
app.post("notes", "update") { req throws -> Response in
    struct UpdateNoteRequest: Content {
        let id: String
        let name: String?
        let body: String?
    }

    let body = try req.content.decode(UpdateNoteRequest.self)
    let result = try notesAPI.updateNote(id: body.id, name: body.name, body: body.body)
    return try responseJSON(["ok": true, "result": result])
}

// POST /notes/delete
app.post("notes", "delete") { req throws -> Response in
    struct DeleteNotesRequest: Content {
        let ids: [String]
    }

    let body = try req.content.decode(DeleteNotesRequest.self)
    let result = try notesAPI.deleteNotes(ids: body.ids)
    return try responseJSON(["ok": true, "result": result])
}

// POST /show
app.post("show") { req throws -> Response in
    struct ShowNoteRequest: Content {
        let id: String
    }

    let body = try req.content.decode(ShowNoteRequest.self)
    let result = try notesAPI.showNote(id: body.id)
    return try responseJSON(["ok": true, "result": result])
}

// GET /search
app.get("search") { req throws -> Response in
    guard let q = req.query[String.self, at: "q"] else {
        throw Abort(.badRequest, reason: "'q' parameter is required")
    }
    let limit = min(req.query[Int.self, at: "limit"] ?? 20, 100)
    let results = try notesAPI.searchNotes(query: q, limit: limit)
    return try responseJSON(["ok": true, "result": results])
}

let port = Int(Environment.get("NOTES_BRIDGE_PORT") ?? "7336") ?? 7336
app.http.server.configuration.hostname = "0.0.0.0"
app.http.server.configuration.port = port

logger.notice("Listening on http://localhost:\(port)")
try app.run()

