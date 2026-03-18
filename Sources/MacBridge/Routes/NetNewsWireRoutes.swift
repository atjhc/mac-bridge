import BridgeCore
import Vapor

func registerNetNewsWireRoutes(on routes: RoutesBuilder, api: NetNewsWireAPI, policy: EndpointPolicy) {
    routes.get("help") { req -> Response in
        let markdown = """
            # NetNewsWire Bridge API

            HTTP bridge to NetNewsWire.

            ## Response format

            All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

            NetNewsWire must be running for this bridge to work.

            ## Identifiers

            Feeds and articles use stable string IDs assigned by NetNewsWire.

            ## Endpoints

            ### GET /nnw/feeds
            List all subscribed feeds. Returns `id`, `name`, `url`, `homepageUrl`.

            ### GET /nnw/articles
            List articles with optional filters.
            - `unread` (default: false) — only unread articles
            - `starred` (default: false) — only starred articles
            - `feedId` — filter to a specific feed
            - `limit` (default: 50, max: 200)
            - `offset` (default: 0) — skip this many articles for pagination
            - `content` (default: false) — include plain-text body (slower)

            Returns: `id`, `title`, `url`, `summary`, `feedName`, `feedId`, `publishedDate`, `arrivedDate`, `read`, `starred`, and optionally `contents`

            ### GET /nnw/article
            Get a single article with full content.
            - `id` (required)

            Returns all article fields plus `permalink`, `externalUrl`, `contents`, `html`

            ### GET /nnw/current
            Get the article currently displayed in the NetNewsWire UI. Returns the same fields as a single article, or null if nothing is selected.

            ### POST /nnw/articles/read
            Mark articles as read or unread.
            - `ids` (required) — array of article ID strings
            - `read` (default: true) — set to false to mark as unread

            ### POST /nnw/articles/starred
            Star or unstar articles.
            - `ids` (required) — array of article ID strings
            - `starred` (default: true) — set to false to unstar

            ### POST /nnw/open
            Open an article in NetNewsWire.
            - `url` — article URL to open
            - `id` — article ID (will look up the URL)

            Provide either `url` or `id`.

            ### GET /nnw/deeplink
            Generate an `nnw://` deep link for an article.
            - `url` — article URL
            - `id` — article ID (will look up the URL)

            Returns: `deeplink`, `url`

            ### GET /nnw/health
            Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

            ### GET /nnw/schema
            Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
            """
        return try responseJSON(["ok": true, "result": ["help": markdown]])
    }

    routes.get("health") { req -> Response in
        let health = checkAppHealth(bundleIdentifier: "com.ranchero.NetNewsWire-Evergreen")
        let result = buildAppHealthResult(
            "nnw-bridge", health: health,
            notInstalled: "NetNewsWire is not installed",
            notRunning: "NetNewsWire is not running")
        return try responseJSON(["ok": true, "result": result])
    }

    routes.get("schema") { req -> Response in
        let schema: [String: Any] = [
            "ok": true,
            "result": [
                "app": "nnw-bridge",
                "endpoints": [
                    [
                        "method": "GET",
                        "path": "/nnw/feeds",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/nnw/articles",
                        "params": [
                            [
                                "name": "unread", "from": "query", "type": "boolean",
                                "default": false,
                            ],
                            [
                                "name": "starred", "from": "query", "type": "boolean",
                                "default": false,
                            ],
                            ["name": "feedId", "from": "query", "type": "string"],
                            ["name": "limit", "from": "query", "type": "number", "default": 50],
                            ["name": "offset", "from": "query", "type": "number", "default": 0],
                            [
                                "name": "content", "from": "query", "type": "boolean",
                                "default": false,
                            ],
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/nnw/article",
                        "params": [
                            ["name": "id", "from": "query", "type": "string", "required": true]
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/nnw/current",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "POST",
                        "path": "/nnw/articles/read",
                        "params": [
                            ["name": "ids", "from": "body", "type": "string[]", "required": true],
                            ["name": "read", "from": "body", "type": "boolean", "default": true],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/nnw/articles/starred",
                        "params": [
                            ["name": "ids", "from": "body", "type": "string[]", "required": true],
                            [
                                "name": "starred", "from": "body", "type": "boolean",
                                "default": true,
                            ],
                        ],
                    ],
                    [
                        "method": "POST",
                        "path": "/nnw/open",
                        "params": [
                            ["name": "url", "from": "body", "type": "string"],
                            ["name": "id", "from": "body", "type": "string"],
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/nnw/deeplink",
                        "params": [
                            ["name": "url", "from": "query", "type": "string"],
                            ["name": "id", "from": "query", "type": "string"],
                        ],
                    ],
                    [
                        "method": "GET",
                        "path": "/nnw/help",
                        "params": [] as [[String: Any]],
                    ],
                    [
                        "method": "GET",
                        "path": "/nnw/health",
                        "params": [] as [[String: Any]],
                    ],
                ],
            ],
        ]
        return try responseJSON(policy.filterSchema(schema, prefix: "nnw"))
    }

    routes.get("feeds") { req async throws -> Response in
        let feeds = try await api.getFeeds()
        return try responseJSON(["ok": true, "result": feeds])
    }

    routes.get("articles") { req async throws -> Response in
        let unread = req.query[Bool.self, at: "unread"] ?? false
        let starred = req.query[Bool.self, at: "starred"] ?? false
        let feedId = req.query[String.self, at: "feedId"]
        let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)
        let offset = max(req.query[Int.self, at: "offset"] ?? 0, 0)
        let content = req.query[Bool.self, at: "content"] ?? false

        let articles = try await api.getArticles(
            unread: unread, starred: starred, feedId: feedId, limit: limit, offset: offset,
            includeContent: content)
        return try responseJSON(["ok": true, "result": articles])
    }

    routes.get("article") { req async throws -> Response in
        guard let id = req.query[String.self, at: "id"] else {
            throw Abort(.badRequest, reason: "'id' parameter is required")
        }
        let article = try await api.getArticle(id: id)
        return try responseJSON(["ok": true, "result": article as Any])
    }

    routes.get("current") { req async throws -> Response in
        let article = try await api.getCurrentArticle()
        return try responseJSON(["ok": true, "result": article as Any])
    }

    routes.post("articles", "read") { req async throws -> Response in
        struct SetReadRequest: Content {
            let ids: [String]
            let read: Bool?
        }

        let body = try req.content.decode(SetReadRequest.self)
        let result = try await api.setReadStatus(ids: body.ids, read: body.read ?? true)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("articles", "starred") { req async throws -> Response in
        struct SetStarredRequest: Content {
            let ids: [String]
            let starred: Bool?
        }

        let body = try req.content.decode(SetStarredRequest.self)
        let result = try await api.setStarredStatus(ids: body.ids, starred: body.starred ?? true)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.post("open") { req async throws -> Response in
        struct OpenRequest: Content {
            let url: String?
            let id: String?
        }

        let body = try req.content.decode(OpenRequest.self)
        let result = try await api.openArticle(url: body.url, id: body.id)
        return try responseJSON(["ok": true, "result": result])
    }

    routes.get("deeplink") { req async throws -> Response in
        let url = req.query[String.self, at: "url"]
        let id = req.query[String.self, at: "id"]
        let result = try await api.getDeeplink(url: url, id: id)
        return try responseJSON(["ok": true, "result": result])
    }
}
