import BridgeCore
import OSLog
import Vapor

struct RateLimitMiddleware: AsyncMiddleware {
    let limiter: RateLimiter
    let log: os.Logger

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let ip = request.headers.first(name: "X-Forwarded-For") ?? "unknown"
        guard await limiter.checkLimit(for: ip) else {
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
        var logLine = "\(request.method.rawValue) \(request.url.path)"
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

struct FormatMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        return try await next.respond(to: request)
    }
}
