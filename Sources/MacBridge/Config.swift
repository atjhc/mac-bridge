import Foundation
import Vapor

struct Config {
    var port: Int = 7330
    var rateLimit: Int = 10
    var disabled: Set<String> = []
    var archiveMailboxes: [String: String] = [:]

    static let filePath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mac-bridge/config")
            .path
    }()

    /// Load config from file, then apply env var overrides.
    static func load() -> Config {
        var config = Config()
        config.applyFile()
        config.applyEnvironment()
        return config
    }

    // MARK: - File parsing

    mutating func applyFile() {
        guard let contents = try? String(contentsOfFile: Self.filePath, encoding: .utf8) else {
            return
        }
        for (key, value) in Self.parse(contents) {
            apply(key: key, value: value)
        }
    }

    /// Parse `key = value` lines. Blank lines and `#` comments are ignored.
    static func parse(_ contents: String) -> [(key: String, value: String)] {
        var results: [(String, String)] = []
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(
                in: .whitespaces)
            results.append((key, value))
        }
        return results
    }

    // MARK: - Env var overrides

    mutating func applyEnvironment() {
        if let v = Environment.get("MACBRIDGE_PORT") { apply(key: "port", value: v) }
        if let v = Environment.get("MACBRIDGE_RATE_LIMIT") { apply(key: "rate-limit", value: v) }
        if let v = Environment.get("MACBRIDGE_DISABLED") { apply(key: "disabled", value: v) }
        if let v = Environment.get("MACBRIDGE_ARCHIVE_MAILBOXES") {
            apply(key: "archive-mailboxes", value: v)
        }
    }

    // MARK: - Key application

    private mutating func apply(key: String, value: String) {
        switch key {
        case "port":
            if let v = Int(value), (1...65535).contains(v) { port = v }
        case "rate-limit":
            if let v = Int(value), v > 0 { rateLimit = v }
        case "disabled":
            disabled = Set(
                value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                })
        case "archive-mailboxes":
            var parsed: [String: String] = [:]
            for entry in value.split(separator: ",") {
                let parts = entry.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                parsed[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
            archiveMailboxes = parsed
        default:
            break
        }
    }

    func isEnabled(_ prefix: String) -> Bool {
        !disabled.contains(prefix)
    }
}
