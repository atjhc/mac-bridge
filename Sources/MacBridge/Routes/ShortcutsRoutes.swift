import BridgeCore
import Vapor

func registerShortcutsRoutes(on routes: RoutesBuilder, api: ShortcutsAPI) {
    routes.get("help") { req -> Response in
        let markdown = """
            # Shortcuts Bridge API

            HTTP bridge to macOS Shortcuts.

            ## Response format

            All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

            Shortcuts must be available for this bridge to work.

            ## Endpoints

            ### GET /shortcuts/shortcuts
            List all shortcuts. Returns `id`, `name`, `folder`.

            ### GET /shortcuts/shortcut
            Get a single shortcut's details.
            - `id` (required)

            ### GET /shortcuts/folders
            List all folders with shortcut counts. Returns `id`, `name`, `shortcutCount`.

            ### POST /shortcuts/run
            Run a shortcut by name or ID.
            - `name` — shortcut name (provide name or id)
            - `id` — shortcut ID
            - `input` — optional input string to pass to the shortcut

            Returns the shortcut's output result.

            ### GET /shortcuts/health
            Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

            ### GET /shortcuts/schema
            Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
            """
        return try responseJSON(["ok": true, "result": ["help": markdown]])
    }

    routes.get("health") { req -> Response in
        let available = FileManager.default.isExecutableFile(atPath: "/usr/bin/shortcuts")
        let result: [String: Any] = [
            "app": "shortcuts-bridge",
            "status": available ? "ok" : "error",
            "error": available ? NSNull() : "shortcuts CLI not found" as Any,
        ]
        return try responseJSON(["ok": true, "result": result])
    }

    routes.get("schema") { req -> Response in
        let schema: [String: Any] = [
            "ok": true,
            "result": [
                "app": "shortcuts-bridge",
                "endpoints": [
                    [
                        "method": "GET",
                        "path": "/shortcuts/shortcuts",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/shortcuts/shortcut",
                        "params": [
                            ["name": "id", "from": "query", "type": "string", "required": true]
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/shortcuts/folders",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "POST",
                        "path": "/shortcuts/run",
                        "params": [
                            ["name": "name", "from": "body", "type": "string"],
                            ["name": "id", "from": "body", "type": "string"],
                            ["name": "input", "from": "body", "type": "string"],
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/shortcuts/help",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/shortcuts/health",
                        "params": [] as [[String: Any]],
                    ],
                ],
            ],
        ]
        return try responseJSON(schema)
    }

    routes.get("shortcuts") { req throws -> Response in
        let shortcuts = try api.getShortcuts()
        return try responseJSON(["ok": true, "result": shortcuts])
    }

    routes.get("shortcut") { req throws -> Response in
        guard let id = req.query[String.self, at: "id"] else {
            throw Abort(.badRequest, reason: "'id' parameter is required")
        }
        let shortcut = try api.getShortcut(id: id)
        return try responseJSON(["ok": true, "result": shortcut as Any])
    }

    routes.get("folders") { req throws -> Response in
        let folders = try api.getFolders()
        return try responseJSON(["ok": true, "result": folders])
    }

    routes.post("run") { req throws -> Response in
        struct RunRequest: Content {
            let name: String?
            let id: String?
            let input: String?
        }

        let body = try req.content.decode(RunRequest.self)
        guard body.name != nil || body.id != nil else {
            throw Abort(.badRequest, reason: "'name' or 'id' is required")
        }
        let result = try api.runShortcut(name: body.name, id: body.id, input: body.input)
        return try responseJSON(["ok": true, "result": result])
    }
}
