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
}
