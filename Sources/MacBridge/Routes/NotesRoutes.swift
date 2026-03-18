import BridgeCore
import Vapor

func registerNotesRoutes(on routes: RoutesBuilder, api: NotesAPI, policy: EndpointPolicy) {
    routes.get("help") { req -> Response in
        let markdown = """
            # Notes Bridge API

            HTTP bridge to Apple Notes.

            ## Response format

            All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

            Notes.app must be running for this bridge to work.

            ## Identifiers

            Notes uses internal string IDs (e.g. `x-coredata://...`). These are stable as long as the note exists.

            ## Endpoints

            ### GET /notes/accounts
            List all Notes accounts. Returns `id` and `name`.

            ### GET /notes/folders
            List folders.
            - `account` — filter to a specific account name

            Returns: `id`, `name`, `shared`

            ### POST /notes/folders
            Create a new folder.
            - `name` (required) — folder name
            - `account` — account name (uses default if omitted)

            Returns: `id` and `name`.

            ### GET /notes/notes
            List notes with optional filters.
            - `folder` — filter by folder name
            - `account` — filter by account name
            - `search` — search in plaintext content
            - `limit` (default: 50, max: 200)
            - `offset` (default: 0) — skip this many matching notes for pagination

            Returns: `{ notes: [...], total: <total notes count>, matched: <matching notes count> }`
            Each note: `id`, `name`, `preview`, `folder`, `creationDate`, `modificationDate`, `passwordProtected`, `shared`

            ### GET /notes/note
            Get a single note with full content.
            - `id` (required)

            Returns: `id`, `name`, `body` (HTML), `plaintext`, `folder`, `creationDate`, `modificationDate`, `passwordProtected`, `shared`

            ### POST /notes/notes
            Create a new note.
            - `name` (required) — note title
            - `body` (required) — note body (HTML supported)
            - `folder` — target folder name
            - `account` — target account name

            Returns: `{"id": "..."}` with the new note's identifier.

            ### POST /notes/notes/update
            Update an existing note.
            - `id` (required) — note ID
            - `name` — new title
            - `body` — new body (HTML supported)

            ### POST /notes/notes/move
            Move notes to a different folder.
            - `ids` (required) — array of note ID strings
            - `folder` (required) — destination folder name
            - `account` — account name (if ambiguous)

            ### POST /notes/notes/delete
            Delete notes by ID.
            - `ids` (required) — array of note ID strings

            ### POST /notes/show
            Open a note in the Notes.app UI.
            - `id` (required) — note ID

            ## Shortcuts-powered endpoints

            These endpoints use Apple Shortcuts for features JXA can't provide. Requires running `scripts/install-shortcuts.sh` once to install the MacBridge shortcuts. Accept either `id` (note ID) or `noteName`.

            ### POST /notes/notes/create-markdown
            Create a note from Markdown content (rendered as rich text).
            - `name` (required) — note title
            - `content` (required) — Markdown body
            - `folder` — target folder name

            ### POST /notes/notes/append-markdown
            Append Markdown content to an existing note.
            - `id` or `noteName` (one required) — target note
            - `markdown` (required) — Markdown to append

            ### POST /notes/checklist
            Add a checklist item (tappable checkbox) to a note.
            - `id` or `noteName` (one required) — target note
            - `text` (required) — checklist item text

            ### POST /notes/tags/add
            Add #hashtag tags to a note (appended to body).
            - `id` (required) — note ID
            - `tags` (required) — array of tag names (with or without # prefix)

            ### POST /notes/tags/remove
            Remove #hashtag tags from a note body.
            - `id` (required) — note ID
            - `tags` (required) — array of tag names to remove

            ### POST /notes/table
            Add a table to a note from CSV data.
            - `id` or `noteName` (one required) — target note
            - `csv` (required) — CSV string (e.g. "Name,Value\\nA,1\\nB,2")
            - `name` — table name

            ### POST /notes/pin
            Pin a note.
            - `id` or `noteName` (one required)

            ### POST /notes/unpin
            Unpin a note.
            - `id` or `noteName` (one required)

            ### GET /notes/search
            Search notes by content. Shorthand for `GET /notes/notes?search=...`.
            - `q` (required) — search term
            - `limit` (default: 20, max: 100)

            Returns: `id`, `name`, `preview`, `folder`, `modificationDate`

            ### GET /notes/health
            Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

            ### GET /notes/schema
            Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
            """
        return try responseJSON(["ok": true, "result": ["help": markdown]])
    }

    routes.get("health") { req -> Response in
        let health = checkAppHealth(bundleIdentifier: "com.apple.Notes")
        let result = buildAppHealthResult(
            "notes-bridge", health: health,
            notInstalled: "Notes.app is not installed",
            notRunning: "Notes.app is not running")
        return try responseJSON(["ok": true, "result": result])
    }

    routes.get("schema") { req -> Response in
        let crudEndpoints: [[String: Any]] = [
            ["method": "GET", "path": "/notes/accounts", "params": [] as [[String: Any]]],
            ["method": "GET", "path": "/notes/folders",
             "params": [["name": "account", "from": "query", "type": "string"]] as [[String: Any]]],
            ["method": "POST", "path": "/notes/folders",
             "params": [
                ["name": "name", "from": "body", "type": "string", "required": true],
                ["name": "account", "from": "body", "type": "string"],
             ] as [[String: Any]]],
            ["method": "GET", "path": "/notes/notes",
             "params": [
                ["name": "folder", "from": "query", "type": "string"],
                ["name": "account", "from": "query", "type": "string"],
                ["name": "search", "from": "query", "type": "string"],
                ["name": "limit", "from": "query", "type": "number", "default": 50],
                ["name": "offset", "from": "query", "type": "number", "default": 0],
             ] as [[String: Any]]],
            ["method": "GET", "path": "/notes/note",
             "params": [["name": "id", "from": "query", "type": "string", "required": true]] as [[String: Any]]],
            ["method": "POST", "path": "/notes/notes",
             "params": [
                ["name": "name", "from": "body", "type": "string", "required": true],
                ["name": "body", "from": "body", "type": "string", "required": true],
                ["name": "folder", "from": "body", "type": "string"],
                ["name": "account", "from": "body", "type": "string"],
             ] as [[String: Any]]],
            ["method": "POST", "path": "/notes/notes/update",
             "params": [
                ["name": "id", "from": "body", "type": "string", "required": true],
                ["name": "name", "from": "body", "type": "string"],
                ["name": "body", "from": "body", "type": "string"],
             ] as [[String: Any]]],
            ["method": "POST", "path": "/notes/notes/move",
             "params": [
                ["name": "ids", "from": "body", "type": "string[]", "required": true],
                ["name": "folder", "from": "body", "type": "string", "required": true],
                ["name": "account", "from": "body", "type": "string"],
             ] as [[String: Any]]],
            ["method": "POST", "path": "/notes/notes/delete",
             "params": [["name": "ids", "from": "body", "type": "string[]", "required": true]] as [[String: Any]]],
            ["method": "POST", "path": "/notes/show",
             "params": [["name": "id", "from": "body", "type": "string", "required": true]] as [[String: Any]]],
        ]

        let shortcutEndpoints: [[String: Any]] = [
            ["method": "POST", "path": "/notes/notes/create-markdown",
             "params": [
                ["name": "name", "from": "body", "type": "string", "required": true],
                ["name": "content", "from": "body", "type": "string", "required": true],
                ["name": "folder", "from": "body", "type": "string"],
             ] as [[String: Any]]],
            ["method": "POST", "path": "/notes/notes/append-markdown",
             "params": [
                ["name": "id", "from": "body", "type": "string"],
                ["name": "noteName", "from": "body", "type": "string"],
                ["name": "markdown", "from": "body", "type": "string", "required": true],
             ] as [[String: Any]]],
            ["method": "POST", "path": "/notes/checklist",
             "params": [
                ["name": "id", "from": "body", "type": "string"],
                ["name": "noteName", "from": "body", "type": "string"],
                ["name": "text", "from": "body", "type": "string", "required": true],
             ] as [[String: Any]]],
            ["method": "POST", "path": "/notes/tags/add",
             "params": [
                ["name": "id", "from": "body", "type": "string", "required": true],
                ["name": "tags", "from": "body", "type": "string[]", "required": true],
             ] as [[String: Any]]],
            ["method": "POST", "path": "/notes/tags/remove",
             "params": [
                ["name": "id", "from": "body", "type": "string", "required": true],
                ["name": "tags", "from": "body", "type": "string[]", "required": true],
             ] as [[String: Any]]],
            ["method": "POST", "path": "/notes/table",
             "params": [
                ["name": "id", "from": "body", "type": "string"],
                ["name": "noteName", "from": "body", "type": "string"],
                ["name": "csv", "from": "body", "type": "string", "required": true],
                ["name": "name", "from": "body", "type": "string"],
             ] as [[String: Any]]],
            ["method": "POST", "path": "/notes/pin",
             "params": [
                ["name": "id", "from": "body", "type": "string"],
                ["name": "noteName", "from": "body", "type": "string"],
             ] as [[String: Any]]],
            ["method": "POST", "path": "/notes/unpin",
             "params": [
                ["name": "id", "from": "body", "type": "string"],
                ["name": "noteName", "from": "body", "type": "string"],
             ] as [[String: Any]]],
            ["method": "GET", "path": "/notes/search",
             "params": [
                ["name": "q", "from": "query", "type": "string", "required": true],
                ["name": "limit", "from": "query", "type": "number", "default": 20],
             ] as [[String: Any]]],
            ["method": "GET", "path": "/notes/help", "params": [] as [[String: Any]]],
            ["method": "GET", "path": "/notes/health", "params": [] as [[String: Any]]],
        ]

        let endpoints: [[String: Any]] = crudEndpoints + shortcutEndpoints
        let schema: [String: Any] = [
            "ok": true,
            "result": [
                "app": "notes-bridge",
                "endpoints": endpoints,
            ] as [String: Any],
        ]
        return try responseJSON(policy.filterSchema(schema, prefix: "notes"))
    }

    routes.get("accounts") { req async throws -> Response in
        let accounts = try await api.getAccounts()
        return try responseJSON(["ok": true, "result": accounts])
    }

    routes.get("folders") { req async throws -> Response in
        let account = req.query[String.self, at: "account"]
        let folders = try await api.getFolders(account: account)
        return try responseJSON(["ok": true, "result": folders])
    }

    routes.post("folders") { req async throws -> Response in
        struct CreateFolderRequest: Content {
            let name: String
            let account: String?
        }

        let body = try req.content.decode(CreateFolderRequest.self)
        let result = try await api.createFolder(name: body.name, account: body.account)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.get("notes") { req async throws -> Response in
        let folder = req.query[String.self, at: "folder"]
        let account = req.query[String.self, at: "account"]
        let search = req.query[String.self, at: "search"]
        let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)
        let offset = max(req.query[Int.self, at: "offset"] ?? 0, 0)

        let notes = try await api.getNotes(
            folder: folder, account: account, search: search, limit: limit, offset: offset)
        return try responseJSON(["ok": true, "result": notes])
    }

    routes.get("note") { req async throws -> Response in
        guard let id = req.query[String.self, at: "id"] else {
            throw Abort(.badRequest, reason: "'id' parameter is required")
        }
        let note = try await api.getNote(id: id)
        return try responseJSON(["ok": true, "result": note as Any])
    }

    routes.post("notes") { req async throws -> Response in
        struct CreateNoteRequest: Content {
            let name: String
            let body: String
            let folder: String?
            let account: String?
        }

        let body = try req.content.decode(CreateNoteRequest.self)
        let result = try await api.createNote(
            name: body.name, body: body.body, folder: body.folder, account: body.account)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("notes", "update") { req async throws -> Response in
        struct UpdateNoteRequest: Content {
            let id: String
            let name: String?
            let body: String?
        }

        let body = try req.content.decode(UpdateNoteRequest.self)
        let result = try await api.updateNote(id: body.id, name: body.name, body: body.body)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("notes", "move") { req async throws -> Response in
        struct MoveNotesRequest: Content {
            let ids: [String]
            let folder: String
            let account: String?
        }

        let body = try req.content.decode(MoveNotesRequest.self)
        let result = try await api.moveNotes(ids: body.ids, folder: body.folder, account: body.account)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("notes", "delete") { req async throws -> Response in
        struct DeleteNotesRequest: Content {
            let ids: [String]
        }

        let body = try req.content.decode(DeleteNotesRequest.self)
        let result = try await api.deleteNotes(ids: body.ids)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("show") { req async throws -> Response in
        struct ShowNoteRequest: Content {
            let id: String
        }

        let body = try req.content.decode(ShowNoteRequest.self)
        let result = try await api.showNote(id: body.id)
        return try responseJSON(["ok": true, "result": result])
    }

    // MARK: - Shortcuts-based endpoints

    routes.post("notes", "create-markdown") { req async throws -> Response in
        struct CreateMarkdownRequest: Content {
            let name: String
            let content: String
            let folder: String?
        }

        let body = try req.content.decode(CreateMarkdownRequest.self)
        let result = try await api.createNoteFromMarkdown(
            name: body.name, markdown: body.content, folder: body.folder)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("notes", "append-markdown") { req async throws -> Response in
        struct AppendMarkdownRequest: Content {
            let id: String?
            let noteName: String?
            let markdown: String
        }

        let body = try req.content.decode(AppendMarkdownRequest.self)
        let result = try await api.appendMarkdown(
            id: body.id, noteName: body.noteName, markdown: body.markdown)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("checklist") { req async throws -> Response in
        struct ChecklistRequest: Content {
            let id: String?
            let noteName: String?
            let text: String
        }

        let body = try req.content.decode(ChecklistRequest.self)
        let result = try await api.addChecklistItem(
            id: body.id, noteName: body.noteName, text: body.text)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("tags", "add") { req async throws -> Response in
        struct TagsRequest: Content {
            let id: String
            let tags: [String]
        }

        let body = try req.content.decode(TagsRequest.self)
        let result = try await api.addTags(id: body.id, tags: body.tags)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("tags", "remove") { req async throws -> Response in
        struct TagsRequest: Content {
            let id: String
            let tags: [String]
        }

        let body = try req.content.decode(TagsRequest.self)
        let result = try await api.removeTags(id: body.id, tags: body.tags)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("table") { req async throws -> Response in
        struct TableRequest: Content {
            let id: String?
            let noteName: String?
            let csv: String
            let name: String?
        }

        let body = try req.content.decode(TableRequest.self)
        let result = try await api.addTable(
            id: body.id, noteName: body.noteName, csv: body.csv, tableName: body.name)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("pin") { req async throws -> Response in
        struct PinRequest: Content {
            let id: String?
            let noteName: String?
        }

        let body = try req.content.decode(PinRequest.self)
        let result = try await api.pinNote(id: body.id, noteName: body.noteName)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("unpin") { req async throws -> Response in
        struct PinRequest: Content {
            let id: String?
            let noteName: String?
        }

        let body = try req.content.decode(PinRequest.self)
        let result = try await api.unpinNote(id: body.id, noteName: body.noteName)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.get("search") { req async throws -> Response in
        guard let q = req.query[String.self, at: "q"] else {
            throw Abort(.badRequest, reason: "'q' parameter is required")
        }
        let limit = min(req.query[Int.self, at: "limit"] ?? 20, 100)
        let results = try await api.searchNotes(query: q, limit: limit)
        return try responseJSON(["ok": true, "result": results])
    }
}
