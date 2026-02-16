import OSLog
import Vapor

public struct RateLimitMiddleware: AsyncMiddleware {
    let limiter: RateLimiter
    let log: os.Logger

    public init(limiter: RateLimiter, log: os.Logger) {
        self.limiter = limiter
        self.log = log
    }

    public func respond(to request: Request, chainingTo next: AsyncResponder) async throws
        -> Response
    {
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

public struct LoggingMiddleware: AsyncMiddleware {
    let log: os.Logger

    public init(log: os.Logger) {
        self.log = log
    }

    public func respond(to request: Request, chainingTo next: AsyncResponder) async throws
        -> Response
    {
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

public struct FormatMiddleware: AsyncMiddleware {
    public init() {}

    public func respond(to request: Request, chainingTo next: AsyncResponder) async throws
        -> Response
    {
        let response = try await next.respond(to: request)

        let wantsJSON = request.query[String.self, at: "format"] == "json"
            || request.headers.first(name: .accept)?.contains("application/json") == true
        guard !wantsJSON else { return response }

        let contentType = response.headers.first(name: .contentType) ?? ""
        guard contentType.contains("application/json") else { return response }
        guard let body = response.body.data else { return response }

        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]

        if let ok = json["ok"] as? Bool, !ok {
            let message = json["error"] as? String ?? "Unknown error"
            return markdownResponse("**Error:** \(message)")
        }

        let result = json["result"]
        let markdown = jsonToMarkdown(result)

        return markdownResponse(markdown)
    }

    private func markdownResponse(_ text: String) -> Response {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/markdown; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: text))
    }
}
