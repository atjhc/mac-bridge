import BridgeCore
import Vapor

extension BridgeResponse {
    func vaporResponse() -> Response {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: contentType)
        return Response(
            status: .init(statusCode: Int(statusCode)),
            headers: headers,
            body: .init(data: data)
        )
    }
}

func responseJSON(_ value: Any) throws -> Response {
    try BridgeCore.responseJSON(value).vaporResponse()
}
