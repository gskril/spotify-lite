import Foundation

struct OAuthTokens: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scope: String?

    var isUsable: Bool {
        !accessToken.isEmpty && !refreshToken.isEmpty
    }
}

protocol OAuthTokenStoring: Sendable {
    func load() async throws -> OAuthTokens?
    func save(_ tokens: OAuthTokens) async throws
    func delete() async throws
}

enum SpotifyAuthorizationError: Error, Sendable, Equatable, LocalizedError {
    case missingClientID
    case notAuthorized
    case invalidRegisteredRedirectURI
    case callbackFailed(String)
    case stateMismatch
    case accessDenied(String)
    case tokenRejected(code: String, message: String?)
    case invalidTokenResponse
    case browserCouldNotOpen

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Enter a Spotify Developer client ID before signing in."
        case .notAuthorized:
            return "Spotify authorization is required."
        case .invalidRegisteredRedirectURI:
            return "The registered Spotify redirect URI must be http://127.0.0.1:43821/callback."
        case .callbackFailed(let message):
            return "Spotify did not complete authorization: \(message)"
        case .stateMismatch:
            return "The Spotify authorization response could not be verified. Please try again."
        case .accessDenied(let reason):
            return "Spotify authorization was denied: \(reason)"
        case .tokenRejected(_, let message):
            return message ?? "Spotify rejected the authorization token. Please sign in again."
        case .invalidTokenResponse:
            return "Spotify returned an invalid authorization response."
        case .browserCouldNotOpen:
            return "The Spotify sign-in page could not be opened."
        }
    }

    var requiresReauthorization: Bool {
        switch self {
        case .tokenRejected(let code, _):
            return code == "invalid_grant" || code == "invalid_client"
        case .notAuthorized:
            return true
        default:
            return false
        }
    }
}

protocol SpotifyAccessTokenRefreshing: SpotifyAuthorizing {
    /// Forces a refresh even when the cached access token has not expired.
    /// The API client uses this once after a 401 response.
    func refreshAccessToken() async throws -> String
}
