import Foundation

enum SpotifyAPIError: Error, Sendable, Equatable, LocalizedError {
    case invalidRequest(String)
    case invalidResponse
    case decoding(String)
    case unauthorized(message: String)
    case forbidden(message: String)
    case rateLimited(retryAfter: TimeInterval?, message: String)
    case quotaExceeded(message: String)
    case http(status: Int, reason: String?, message: String)
    case paginationLimitExceeded

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .decoding(let message):
            return message
        case .invalidResponse:
            return "Spotify returned an invalid network response."
        case .unauthorized(let message), .forbidden(let message):
            return message
        case .rateLimited(_, let message):
            return message
        case .quotaExceeded(let message):
            return message
        case .http(_, _, let message):
            return message
        case .paginationLimitExceeded:
            return "Spotify returned too many result pages."
        }
    }
}
