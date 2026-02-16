import Foundation
import Testing

@testable import BridgeCore

@Suite struct RateLimiterTests {
    @Test func allowsUpToLimit() async {
        let limiter = RateLimiter(limit: 3)
        #expect(await limiter.checkLimit(for: "1.2.3.4") == true)
        #expect(await limiter.checkLimit(for: "1.2.3.4") == true)
        #expect(await limiter.checkLimit(for: "1.2.3.4") == true)
    }

    @Test func rejectsAtLimitPlusOne() async {
        let limiter = RateLimiter(limit: 2)
        _ = await limiter.checkLimit(for: "1.2.3.4")
        _ = await limiter.checkLimit(for: "1.2.3.4")
        #expect(await limiter.checkLimit(for: "1.2.3.4") == false)
    }

    @Test func independentPerIP() async {
        let limiter = RateLimiter(limit: 1)
        #expect(await limiter.checkLimit(for: "1.1.1.1") == true)
        #expect(await limiter.checkLimit(for: "2.2.2.2") == true)
        #expect(await limiter.checkLimit(for: "1.1.1.1") == false)
    }

    @Test func resetsAfterWindow() async throws {
        let limiter = RateLimiter(limit: 1, window: 0.1)
        #expect(await limiter.checkLimit(for: "1.2.3.4") == true)
        #expect(await limiter.checkLimit(for: "1.2.3.4") == false)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(await limiter.checkLimit(for: "1.2.3.4") == true)
    }
}
