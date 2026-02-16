import Foundation
import OSLog
import Vapor
import BridgeCore

let logger = os.Logger(subsystem: "com.user.bridge", category: "nnw")

let app = try Application(.detect())
defer { app.shutdown() }

app.logger.logLevel = .notice

let nnwAPI = NetNewsWireAPI()

let rateLimit = Int(Environment.get("RATE_LIMIT_PER_SECOND") ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)
app.middleware.use(RateLimitMiddleware(limiter: rateLimiter, log: logger))
app.middleware.use(LoggingMiddleware(log: logger))
app.middleware.use(FormatMiddleware())

// Help endpoint
app.get("help") { req -> Response in
    let markdown = """
        # NetNewsWire Bridge API

        HTTP bridge to NetNewsWire.

        ## Response format

        All endpoints return **markdown** by default (tables for lists, key-value for single objects). To get JSON instead, either add `?format=json` to the URL or send an `Accept: application/json` header. JSON responses use `{"ok": true, "result": ...}`.

        NetNewsWire must be running for this bridge to work.

        ## Identifiers

        Feeds and articles use stable string IDs assigned by NetNewsWire.

        ## Endpoints

        ### GET /feeds
        List all subscribed feeds. Returns `id`, `name`, `url`, `homepageUrl`.

        ### GET /articles
        List articles with optional filters.
        - `unread` (default: false) — only unread articles
        - `starred` (default: false) — only starred articles
        - `feedId` — filter to a specific feed
        - `limit` (default: 50, max: 200)
        - `content` (default: false) — include plain-text body (slower)

        Returns: `id`, `title`, `url`, `summary`, `feedName`, `feedId`, `publishedDate`, `arrivedDate`, `read`, `starred`, and optionally `contents`

        ### GET /article
        Get a single article with full content.
        - `id` (required)

        Returns all article fields plus `permalink`, `externalUrl`, `contents`, `html`

        ### GET /current
        Get the article currently displayed in the NetNewsWire UI. Returns the same fields as a single article, or null if nothing is selected.

        ### POST /articles/read
        Mark articles as read or unread.
        - `ids` (required) — array of article ID strings
        - `read` (default: true) — set to false to mark as unread

        ### POST /articles/starred
        Star or unstar articles.
        - `ids` (required) — array of article ID strings
        - `starred` (default: true) — set to false to unstar

        ### POST /open
        Open an article in NetNewsWire.
        - `url` — article URL to open
        - `id` — article ID (will look up the URL)

        Provide either `url` or `id`.

        ### GET /deeplink
        Generate an `nnw://` deep link for an article.
        - `url` — article URL
        - `id` — article ID (will look up the URL)

        Returns: `deeplink`, `url`

        ### GET /health
        Returns bridge status. Use `?format=json` for `{"ok": true, "result": {"status": "ok"}}`.

        ### GET /schema
        Returns machine-readable endpoint definitions. Use `?format=json` for structured JSON.
        """
    return try responseJSON(["ok": true, "result": ["help": markdown]])
}

// Health check
app.get("health") { req -> Response in
    let response: [String: Any] = [
        "ok": true,
        "result": [
            "status": "ok",
            "app": "nnw-bridge",
        ],
    ]
    return try responseJSON(response)
}

// Schema endpoint
app.get("schema") { req -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "nnw-bridge",
            "endpoints": [
                [
                    "method": "GET",
                    "path": "/feeds",
                    "params": [],
                ],
                [
                    "method": "GET",
                    "path": "/articles",
                    "params": [
                        ["name": "unread", "from": "query", "type": "boolean", "default": false],
                        ["name": "starred", "from": "query", "type": "boolean", "default": false],
                        ["name": "feedId", "from": "query", "type": "string"],
                        ["name": "limit", "from": "query", "type": "number", "default": 50],
                        ["name": "content", "from": "query", "type": "boolean", "default": false],
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/article",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/current",
                    "params": [],
                ],
                [
                    "method": "POST",
                    "path": "/articles/read",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "read", "from": "body", "type": "boolean", "default": true],
                    ],
                ],
                [
                    "method": "POST",
                    "path": "/articles/starred",
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
                    "path": "/open",
                    "params": [
                        ["name": "url", "from": "body", "type": "string"],
                        ["name": "id", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "GET",
                    "path": "/deeplink",
                    "params": [
                        ["name": "url", "from": "query", "type": "string"],
                        ["name": "id", "from": "query", "type": "string"],
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

// GET /feeds
app.get("feeds") { req throws -> Response in
    let feeds = try nnwAPI.getFeeds()
    return try responseJSON(["ok": true, "result": feeds])
}

// GET /articles
app.get("articles") { req throws -> Response in
    let unread = req.query[Bool.self, at: "unread"] ?? false
    let starred = req.query[Bool.self, at: "starred"] ?? false
    let feedId = req.query[String.self, at: "feedId"]
    let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)
    let content = req.query[Bool.self, at: "content"] ?? false

    let articles = try nnwAPI.getArticles(
        unread: unread, starred: starred, feedId: feedId, limit: limit, includeContent: content)
    return try responseJSON(["ok": true, "result": articles])
}

// GET /article
app.get("article") { req throws -> Response in
    guard let id = req.query[String.self, at: "id"] else {
        throw Abort(.badRequest, reason: "'id' parameter is required")
    }
    let article = try nnwAPI.getArticle(id: id)
    return try responseJSON(["ok": true, "result": article as Any])
}

// GET /current
app.get("current") { req throws -> Response in
    let article = try nnwAPI.getCurrentArticle()
    return try responseJSON(["ok": true, "result": article as Any])
}

// POST /articles/read
app.post("articles", "read") { req throws -> Response in
    struct SetReadRequest: Content {
        let ids: [String]
        let read: Bool?
    }

    let body = try req.content.decode(SetReadRequest.self)
    let result = try nnwAPI.setReadStatus(ids: body.ids, read: body.read ?? true)
    return try responseJSON(["ok": true, "result": result])
}

// POST /articles/starred
app.post("articles", "starred") { req throws -> Response in
    struct SetStarredRequest: Content {
        let ids: [String]
        let starred: Bool?
    }

    let body = try req.content.decode(SetStarredRequest.self)
    let result = try nnwAPI.setStarredStatus(ids: body.ids, starred: body.starred ?? true)
    return try responseJSON(["ok": true, "result": result])
}

// POST /open
app.post("open") { req throws -> Response in
    struct OpenRequest: Content {
        let url: String?
        let id: String?
    }

    let body = try req.content.decode(OpenRequest.self)
    let result = try nnwAPI.openArticle(url: body.url, id: body.id)
    return try responseJSON(["ok": true, "result": result])
}

// GET /deeplink
app.get("deeplink") { req throws -> Response in
    let url = req.query[String.self, at: "url"]
    let id = req.query[String.self, at: "id"]
    let result = try nnwAPI.getDeeplink(url: url, id: id)
    return try responseJSON(["ok": true, "result": result])
}

let port = Int(Environment.get("NNW_BRIDGE_PORT") ?? "7331") ?? 7331
app.http.server.configuration.hostname = "0.0.0.0"
app.http.server.configuration.port = port

logger.notice("Listening on http://localhost:\(port)")
try app.run()

