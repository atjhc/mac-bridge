@_exported import BridgeCore
import Hummingbird
import NIOCore

public enum BridgeFormat {
    @TaskLocal public static var wantsJSON = false
}

extension BridgeResponse {
    public func hbResponse() -> Response {
        var response = Response(status: .init(code: Int(statusCode)))
        response.headers[.contentType] = contentType
        response.body = .init(byteBuffer: ByteBuffer(data: data))
        return response
    }
}

public func bridgeResponse(_ value: Any) throws -> Response {
    let json = try responseJSON(value)
    if !BridgeFormat.wantsJSON, let formatted = formatJSONAsMarkdown(json.data) {
        return formatted.hbResponse()
    }
    return json.hbResponse()
}
