import Foundation

public actor RateLimiter {
    private var requests: [String: [Date]] = [:]
    private let limit: Int
    private let window: TimeInterval

    public init(limit: Int, window: TimeInterval = 1.0) {
        self.limit = limit
        self.window = window
    }

    public func checkLimit(for ip: String) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-window)

        requests[ip] = requests[ip]?.filter { $0 > cutoff } ?? []

        let count = requests[ip]?.count ?? 0
        if count >= limit {
            return false
        }

        requests[ip, default: []].append(now)
        return true
    }
}
