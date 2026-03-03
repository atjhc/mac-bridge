import BridgeHTTP
import Hummingbird
import OSLog

let logger = Logger(subsystem: "com.user.bridge", category: "nnw")

let nnwAPI = NetNewsWireAPI()

let rateLimit = Int(ProcessInfo.processInfo.environment["RATE_LIMIT_PER_SECOND"] ?? "10") ?? 10
let rateLimiter = RateLimiter(limit: rateLimit)

let router = Router()
router.add(middleware: BridgeRateLimitMiddleware(limiter: rateLimiter, log: logger))
router.add(middleware: BridgeLoggingMiddleware(log: logger))
router.add(middleware: BridgeFormatMiddleware())

router.get("help") { _, _ -> Response in
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
    return try bridgeResponse(["ok": true, "result": ["help": markdown]])
}

router.get("health") { _, _ -> Response in
    let result = nnwAPI.healthCheck()
    let isOk = (result["status"] as? String) == "ok"
    return try bridgeResponse(["ok": isOk, "result": result])
}

router.get("schema") { _, _ -> Response in
    let schema: [String: Any] = [
        "ok": true,
        "result": [
            "app": "nnw-bridge",
            "endpoints": [
                ["method": "GET", "path": "/feeds", "params": []],
                [
                    "method": "GET", "path": "/articles",
                    "params": [
                        ["name": "unread", "from": "query", "type": "boolean", "default": false],
                        ["name": "starred", "from": "query", "type": "boolean", "default": false],
                        ["name": "feedId", "from": "query", "type": "string"],
                        ["name": "limit", "from": "query", "type": "number", "default": 50],
                        ["name": "content", "from": "query", "type": "boolean", "default": false],
                    ],
                ],
                [
                    "method": "GET", "path": "/article",
                    "params": [
                        ["name": "id", "from": "query", "type": "string", "required": true]
                    ],
                ],
                ["method": "GET", "path": "/current", "params": []],
                [
                    "method": "POST", "path": "/articles/read",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "read", "from": "body", "type": "boolean", "default": true],
                    ],
                ],
                [
                    "method": "POST", "path": "/articles/starred",
                    "params": [
                        ["name": "ids", "from": "body", "type": "string[]", "required": true],
                        ["name": "starred", "from": "body", "type": "boolean", "default": true],
                    ],
                ],
                [
                    "method": "POST", "path": "/open",
                    "params": [
                        ["name": "url", "from": "body", "type": "string"],
                        ["name": "id", "from": "body", "type": "string"],
                    ],
                ],
                [
                    "method": "GET", "path": "/deeplink",
                    "params": [
                        ["name": "url", "from": "query", "type": "string"],
                        ["name": "id", "from": "query", "type": "string"],
                    ],
                ],
                ["method": "GET", "path": "/help", "params": []],
                ["method": "GET", "path": "/health", "params": []],
            ],
        ],
    ]
    return try bridgeResponse(schema)
}

router.get("feeds") { _, _ async throws -> Response in
    let feeds = try await nnwAPI.getFeeds()
    return try bridgeResponse(["ok": true, "result": feeds])
}

router.get("articles") { req, _ async throws -> Response in
    let unread = req.uri.queryParameters.get("unread") == "true"
    let starred = req.uri.queryParameters.get("starred") == "true"
    let feedId: String? = req.uri.queryParameters.get("feedId")
    let limit = min(Int(req.uri.queryParameters.get("limit") ?? "") ?? 50, 200)
    let content = req.uri.queryParameters.get("content") == "true"

    let articles = try await nnwAPI.getArticles(
        unread: unread, starred: starred, feedId: feedId, limit: limit, includeContent: content)
    return try bridgeResponse(["ok": true, "result": articles])
}

router.get("article") { req, _ async throws -> Response in
    guard let id: String = req.uri.queryParameters.get("id") else {
        throw HTTPError(.badRequest, message: "'id' parameter is required")
    }
    let article = try await nnwAPI.getArticle(id: id)
    return try bridgeResponse(["ok": true, "result": article as Any])
}

router.get("current") { _, _ async throws -> Response in
    let article = try await nnwAPI.getCurrentArticle()
    return try bridgeResponse(["ok": true, "result": article as Any])
}

router.post("articles/read") { req, ctx async throws -> Response in
    struct SetReadRequest: Decodable {
        let ids: [String]
        let read: Bool?
    }

    let body = try await req.decode(as: SetReadRequest.self, context: ctx)
    let result = try await nnwAPI.setReadStatus(ids: body.ids, read: body.read ?? true)
    return try bridgeResponse(["ok": true, "result": result])
}

router.post("articles/starred") { req, ctx async throws -> Response in
    struct SetStarredRequest: Decodable {
        let ids: [String]
        let starred: Bool?
    }

    let body = try await req.decode(as: SetStarredRequest.self, context: ctx)
    let result = try await nnwAPI.setStarredStatus(ids: body.ids, starred: body.starred ?? true)
    return try bridgeResponse(["ok": true, "result": result])
}

router.post("open") { req, ctx async throws -> Response in
    struct OpenRequest: Decodable {
        let url: String?
        let id: String?
    }

    let body = try await req.decode(as: OpenRequest.self, context: ctx)
    let result = try await nnwAPI.openArticle(url: body.url, id: body.id)
    return try bridgeResponse(["ok": true, "result": result])
}

router.get("deeplink") { req, _ async throws -> Response in
    let url: String? = req.uri.queryParameters.get("url")
    let id: String? = req.uri.queryParameters.get("id")
    let result = try await nnwAPI.getDeeplink(url: url, id: id)
    return try bridgeResponse(["ok": true, "result": result])
}

let port = Int(ProcessInfo.processInfo.environment["NNW_BRIDGE_PORT"] ?? "7331") ?? 7331
logger.notice("Listening on http://localhost:\(port)")

let app = Application(
    router: router,
    configuration: .init(address: .hostname("0.0.0.0", port: port))
)
try await app.runService()
