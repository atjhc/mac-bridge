import Foundation

enum BridgeError: Error, LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return msg
        }
    }
}
