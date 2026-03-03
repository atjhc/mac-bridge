import BridgeCore
import HTTPTypes
import Hummingbird
import NIOCore
import OSLog

private let xForwardedFor = HTTPField.Name("X-Forwarded-For")!

public struct BridgeRateLimitMiddleware<Context: RequestContext>: MiddlewareProtocol {
    let limiter: RateLimiter
    let log: os.Logger

    public init(limiter: RateLimiter, log: os.Logger) {
        self.limiter = limiter
        self.log = log
    }

    public func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let ip: String =
            request.headers[values: xForwardedFor].first.map { String($0) }
            ?? "unknown"

        guard await limiter.checkLimit(for: ip) else {
            log.warning("Rate limit exceeded for \(ip, privacy: .public)")
            throw HTTPError(.tooManyRequests, message: "Rate limit exceeded")
        }

        return try await next(request, context)
    }
}

public struct BridgeLoggingMiddleware<Context: RequestContext>: MiddlewareProtocol {
    let log: os.Logger

    public init(log: os.Logger) {
        self.log = log
    }

    public func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let start = Date()

        var logLine = "\(request.method) \(request.uri.path)"
        if let query = request.uri.query, !query.isEmpty {
            logLine += "?\(query)"
        }
        log.info("\(logLine, privacy: .public)")

        let response = try await next(request, context)
        let duration = Date().timeIntervalSince(start) * 1000

        log.info("\(logLine, privacy: .public) → \(response.status.code) (\(Int(duration))ms)")

        return response
    }
}

public struct BridgeFormatMiddleware<Context: RequestContext>: MiddlewareProtocol {
    public init() {}

    public func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let wantsJSON =
            request.uri.queryParameters.get("format") == "json"
            || request.headers[values: .accept].contains(where: { $0.contains("application/json") })

        return try await BridgeFormat.$wantsJSON.withValue(wantsJSON) {
            try await next(request, context)
        }
    }
}
