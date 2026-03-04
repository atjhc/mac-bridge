import Testing

@testable import BridgeCore

@Suite("EndpointPolicy")
struct EndpointPolicyTests {

    // MARK: - Exempt paths

    @Test("health, help, schema are always accessible")
    func exemptPaths() {
        let policy = EndpointPolicy(readOnly: true, denied: ["health"], allowed: Set(["foo"]))
        #expect(!policy.isBlocked(path: "health", method: "GET"))
        #expect(!policy.isBlocked(path: "help", method: "GET"))
        #expect(!policy.isBlocked(path: "schema", method: "GET"))
        #expect(!policy.isBlocked(path: "/health", method: "POST"))
        #expect(!policy.isBlocked(path: "/help/", method: "POST"))
    }

    // MARK: - Read-only

    @Test("read-only blocks POST but allows GET")
    func readOnly() {
        let policy = EndpointPolicy(readOnly: true)
        #expect(policy.isBlocked(path: "todos", method: "POST"))
        #expect(!policy.isBlocked(path: "todos", method: "GET"))
    }

    @Test("read-only does not block exempt POST")
    func readOnlyExempt() {
        let policy = EndpointPolicy(readOnly: true)
        #expect(!policy.isBlocked(path: "health", method: "POST"))
    }

    // MARK: - Denylist

    @Test("denied paths are blocked")
    func denylist() {
        let policy = EndpointPolicy(denied: ["notes/delete", "notes/update"])
        #expect(policy.isBlocked(path: "notes/delete", method: "POST"))
        #expect(policy.isBlocked(path: "notes/update", method: "POST"))
        #expect(!policy.isBlocked(path: "notes", method: "GET"))
    }

    @Test("denied paths trim slashes")
    func denylistTrimSlashes() {
        let policy = EndpointPolicy(denied: ["todos/delete"])
        #expect(policy.isBlocked(path: "/todos/delete", method: "POST"))
        #expect(policy.isBlocked(path: "/todos/delete/", method: "POST"))
    }

    // MARK: - Allowlist

    @Test("allowlist permits only listed paths")
    func allowlist() {
        let policy = EndpointPolicy(allowed: Set(["mailboxes", "messages", "message"]))
        #expect(!policy.isBlocked(path: "mailboxes", method: "GET"))
        #expect(!policy.isBlocked(path: "messages", method: "GET"))
        #expect(policy.isBlocked(path: "folders", method: "GET"))
        #expect(policy.isBlocked(path: "compose", method: "POST"))
    }

    @Test("allowlist still permits exempt paths")
    func allowlistExempt() {
        let policy = EndpointPolicy(allowed: Set(["mailboxes"]))
        #expect(!policy.isBlocked(path: "health", method: "GET"))
        #expect(!policy.isBlocked(path: "help", method: "GET"))
        #expect(!policy.isBlocked(path: "schema", method: "GET"))
    }

    // MARK: - Allow takes precedence over deny

    @Test("allowlist takes precedence over denylist")
    func allowOverDeny() {
        let policy = EndpointPolicy(
            denied: ["mailboxes"], allowed: Set(["mailboxes", "messages"]))
        #expect(!policy.isBlocked(path: "mailboxes", method: "GET"))
        #expect(policy.isBlocked(path: "compose", method: "POST"))
    }

    // MARK: - Default policy

    @Test("default policy blocks nothing")
    func defaultPolicy() {
        let policy = EndpointPolicy()
        #expect(!policy.isBlocked(path: "anything", method: "GET"))
        #expect(!policy.isBlocked(path: "anything", method: "POST"))
    }

    // MARK: - Combined read-only + allowlist

    @Test("read-only + allowlist blocks POST even for allowed paths")
    func readOnlyWithAllowlist() {
        let policy = EndpointPolicy(readOnly: true, allowed: Set(["todos"]))
        #expect(!policy.isBlocked(path: "todos", method: "GET"))
        #expect(policy.isBlocked(path: "todos", method: "POST"))
        #expect(policy.isBlocked(path: "other", method: "GET"))
    }
}
