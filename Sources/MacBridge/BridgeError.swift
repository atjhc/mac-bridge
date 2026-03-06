import BridgeCore
import Vapor

extension BridgeError: AbortError {
    public var status: HTTPResponseStatus { .internalServerError }
    public var reason: String { errorDescription ?? "Unknown error" }
}
