import Foundation

public struct BridgeResponse: Sendable {
    public let data: Data
    public let contentType: String
    public let statusCode: UInt

    public init(data: Data, contentType: String, statusCode: UInt = 200) {
        self.data = data
        self.contentType = contentType
        self.statusCode = statusCode
    }
}

public func responseJSON(_ value: Any) throws -> BridgeResponse {
    let data = try JSONSerialization.data(withJSONObject: value)
    return BridgeResponse(data: data, contentType: "application/json")
}

public func markdownResponse(_ text: String) -> BridgeResponse {
    BridgeResponse(data: Data(text.utf8), contentType: "text/markdown; charset=utf-8")
}

public func formatJSONAsMarkdown(_ jsonData: Data) -> BridgeResponse? {
    guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        return nil
    }
    if let ok = json["ok"] as? Bool, !ok {
        let message = json["error"] as? String ?? "Unknown error"
        return markdownResponse("**Error:** \(message)")
    }
    return markdownResponse(jsonToMarkdown(json["result"]))
}
