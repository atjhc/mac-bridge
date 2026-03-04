import Foundation

public struct EndpointPolicy: Sendable {
    public var readOnly: Bool
    public var denied: Set<String>
    public var allowed: Set<String>?

    public init(readOnly: Bool = false, denied: Set<String> = [], allowed: Set<String>? = nil) {
        self.readOnly = readOnly
        self.denied = denied
        self.allowed = allowed
    }

    private static let exempt: Set<String> = ["health", "help", "schema"]

    public func isBlocked(path: String, method: String) -> Bool {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !Self.exempt.contains(clean) else { return false }
        if readOnly && method == "POST" { return true }
        if let allowed {
            return !allowed.contains(clean)
        }
        return denied.contains(clean)
    }

    /// Removes blocked endpoints from a schema dictionary.
    /// Expects `{"ok": true, "result": {"endpoints": [{"method": ..., "path": ...}]}}`.
    public func filterSchema(_ schema: [String: Any], prefix: String) -> [String: Any] {
        guard var result = schema["result"] as? [String: Any],
            let endpoints = result["endpoints"] as? [[String: Any]]
        else { return schema }
        let prefixSlash = "/\(prefix)/"
        result["endpoints"] = endpoints.filter { endpoint in
            guard let method = endpoint["method"] as? String,
                let path = endpoint["path"] as? String
            else { return true }
            var relative = path
            if relative.hasPrefix(prefixSlash) {
                relative = String(relative.dropFirst(prefixSlash.count))
            }
            return !isBlocked(path: relative, method: method)
        }
        var filtered = schema
        filtered["result"] = result
        return filtered
    }
}
