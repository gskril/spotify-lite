import AppKit
import Foundation

protocol AuthorizationURLOpening: Sendable {
    func open(_ url: URL) async throws
}

struct SystemAuthorizationURLOpener: AuthorizationURLOpening {
    func open(_ url: URL) async throws {
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw SpotifyAuthorizationError.browserCouldNotOpen }
    }
}

actor SpotifyAuthorizer: SpotifyAccessTokenRefreshing {
    struct Configuration: Sendable {
        var authorizationEndpoint = URL(string: "https://accounts.spotify.com/authorize")!
        var tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!
        /// Spotify's dashboard currently rejects the documented portless loopback
        /// form, so the app and dashboard use this exact fixed loopback URI.
        var registeredRedirectURI = URL(string: "http://127.0.0.1:43821/callback")!
        var refreshLeeway: TimeInterval = 60
        var scopes: [String] = [
            "user-read-playback-state",
            "user-read-currently-playing",
            "user-modify-playback-state",
            "user-library-read",
            "user-library-modify",
            "playlist-read-private",
            "playlist-read-collaborative",
            "user-read-recently-played"
        ]
    }

    private let clientIDProvider: @Sendable () async throws -> String
    private let tokenStore: any OAuthTokenStoring
    private let callbackListener: any OAuthCallbackListening
    private let urlOpener: any AuthorizationURLOpening
    private let session: URLSession
    private let configuration: Configuration
    private let now: @Sendable () -> Date

    private var authorizationTask: (id: UUID, task: Task<Void, Error>)?
    private var refreshTask: (id: UUID, task: Task<OAuthTokens, Error>)?

    init(
        clientID: String,
        tokenStore: any OAuthTokenStoring = KeychainTokenStore(),
        callbackListener: any OAuthCallbackListening = LoopbackOAuthCallbackListener(),
        urlOpener: any AuthorizationURLOpening = SystemAuthorizationURLOpener(),
        session: URLSession = .shared,
        configuration: Configuration = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.clientIDProvider = { clientID }
        self.tokenStore = tokenStore
        self.callbackListener = callbackListener
        self.urlOpener = urlOpener
        self.session = session
        self.configuration = configuration
        self.now = now
    }

    init(
        clientIDStore: SpotifyClientIDStore,
        tokenStore: any OAuthTokenStoring = KeychainTokenStore(),
        callbackListener: any OAuthCallbackListening = LoopbackOAuthCallbackListener(),
        urlOpener: any AuthorizationURLOpening = SystemAuthorizationURLOpener(),
        session: URLSession = .shared,
        configuration: Configuration = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.clientIDProvider = {
            guard let clientID = await clientIDStore.clientID() else {
                throw SpotifyAuthorizationError.missingClientID
            }
            return clientID
        }
        self.tokenStore = tokenStore
        self.callbackListener = callbackListener
        self.urlOpener = urlOpener
        self.session = session
        self.configuration = configuration
        self.now = now
    }

    func beginAuthorization() async throws {
        if let authorizationTask {
            return try await authorizationTask.task.value
        }

        let id = UUID()
        let task = Task { try await self.performAuthorization() }
        authorizationTask = (id, task)
        do {
            try await task.value
            clearAuthorizationTask(id: id)
        } catch {
            clearAuthorizationTask(id: id)
            throw error
        }
    }

    func validAccessToken() async throws -> String {
        guard let tokens = try await tokenStore.load(), tokens.isUsable else {
            throw SpotifyAuthorizationError.notAuthorized
        }
        if tokens.expiresAt.timeIntervalSince(now()) > configuration.refreshLeeway {
            return tokens.accessToken
        }
        return try await refresh(using: tokens)
    }

    func refreshAccessToken() async throws -> String {
        guard let tokens = try await tokenStore.load(), tokens.isUsable else {
            throw SpotifyAuthorizationError.notAuthorized
        }
        return try await refresh(using: tokens)
    }

    func signOut() async throws {
        authorizationTask?.task.cancel()
        refreshTask?.task.cancel()
        authorizationTask = nil
        refreshTask = nil
        try await tokenStore.delete()
    }

    private func performAuthorization() async throws {
        let clientID = try await normalizedClientID()
        let callbackPath = try validatedCallbackPath()
        let verifier = try PKCE.verifier()
        let state = try PKCE.state()
        let receiver = try await callbackListener.start(callbackPath: callbackPath)
        defer { receiver.cancel() }

        let authorizationURL = try Self.makeAuthorizationURL(
            endpoint: configuration.authorizationEndpoint,
            clientID: clientID,
            redirectURI: receiver.redirectURI,
            scopes: configuration.scopes,
            state: state,
            challenge: PKCE.challenge(for: verifier)
        )
        try await urlOpener.open(authorizationURL)

        let callbackURL: URL
        do {
            callbackURL = try await receiver.waitForCallback()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpotifyAuthorizationError.callbackFailed(error.localizedDescription)
        }

        let code = try Self.authorizationCode(from: callbackURL, expectedState: state)
        let tokens = try await Self.exchangeCode(
            code,
            verifier: verifier,
            clientID: clientID,
            redirectURI: receiver.redirectURI,
            endpoint: configuration.tokenEndpoint,
            session: session,
            now: now()
        )
        try await tokenStore.save(tokens)
    }

    private func refresh(using existingTokens: OAuthTokens) async throws -> String {
        if let refreshTask {
            return try await refreshTask.task.value.accessToken
        }

        let clientID = try await normalizedClientID()
        let id = UUID()
        let endpoint = configuration.tokenEndpoint
        let session = session
        let currentDate = now()
        let task = Task {
            try await Self.exchangeRefreshToken(
                existingTokens.refreshToken,
                existingScope: existingTokens.scope,
                clientID: clientID,
                endpoint: endpoint,
                session: session,
                now: currentDate
            )
        }
        refreshTask = (id, task)

        do {
            let tokens = try await task.value
            try await tokenStore.save(tokens)
            clearRefreshTask(id: id)
            return tokens.accessToken
        } catch {
            clearRefreshTask(id: id)
            if let authorizationError = error as? SpotifyAuthorizationError,
               authorizationError.requiresReauthorization {
                try? await tokenStore.delete()
            }
            throw error
        }
    }

    private func normalizedClientID() async throws -> String {
        let clientID = try await clientIDProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw SpotifyAuthorizationError.missingClientID }
        return clientID
    }

    private func validatedCallbackPath() throws -> String {
        let uri = configuration.registeredRedirectURI
        guard
            uri.scheme?.lowercased() == "http",
            uri.host == "127.0.0.1",
            uri.port == 43_821,
            !uri.path.isEmpty
        else {
            throw SpotifyAuthorizationError.invalidRegisteredRedirectURI
        }
        return uri.path
    }

    private func clearAuthorizationTask(id: UUID) {
        if authorizationTask?.id == id { authorizationTask = nil }
    }

    private func clearRefreshTask(id: UUID) {
        if refreshTask?.id == id { refreshTask = nil }
    }

    static func makeAuthorizationURL(
        endpoint: URL,
        clientID: String,
        redirectURI: URL,
        scopes: [String],
        state: String,
        challenge: String
    ) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw SpotifyAuthorizationError.invalidTokenResponse
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]
        guard let url = components.url else { throw SpotifyAuthorizationError.invalidTokenResponse }
        return url
    }

    static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw SpotifyAuthorizationError.callbackFailed("Malformed callback URL.")
        }
        let values = Dictionary(grouping: components.queryItems ?? [], by: \URLQueryItem.name)
        let state = values["state"]?.first?.value
        guard state == expectedState else { throw SpotifyAuthorizationError.stateMismatch }
        if let error = values["error"]?.first?.value {
            throw SpotifyAuthorizationError.accessDenied(error)
        }
        guard let code = values["code"]?.first?.value, !code.isEmpty else {
            throw SpotifyAuthorizationError.callbackFailed("The authorization code was missing.")
        }
        return code
    }

    private static func exchangeCode(
        _ code: String,
        verifier: String,
        clientID: String,
        redirectURI: URL,
        endpoint: URL,
        session: URLSession,
        now: Date
    ) async throws -> OAuthTokens {
        let response = try await requestToken(
            endpoint: endpoint,
            parameters: [
                URLQueryItem(name: "grant_type", value: "authorization_code"),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "code_verifier", value: verifier)
            ],
            session: session
        )
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw SpotifyAuthorizationError.invalidTokenResponse
        }
        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(max(0, response.expiresIn))),
            scope: response.scope
        )
    }

    private static func exchangeRefreshToken(
        _ refreshToken: String,
        existingScope: String?,
        clientID: String,
        endpoint: URL,
        session: URLSession,
        now: Date
    ) async throws -> OAuthTokens {
        let response = try await requestToken(
            endpoint: endpoint,
            parameters: [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: refreshToken),
                URLQueryItem(name: "client_id", value: clientID)
            ],
            session: session
        )
        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(max(0, response.expiresIn))),
            scope: response.scope ?? existingScope
        )
    }

    private static func requestToken(
        endpoint: URL,
        parameters: [URLQueryItem],
        session: URLSession
    ) async throws -> TokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = parameters
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyAuthorizationError.invalidTokenResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
            throw SpotifyAuthorizationError.tokenRejected(
                code: error?.error ?? "http_\(http.statusCode)",
                message: error?.errorDescription
            )
        }
        do {
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            guard !decoded.accessToken.isEmpty else { throw SpotifyAuthorizationError.invalidTokenResponse }
            return decoded
        } catch let error as SpotifyAuthorizationError {
            throw error
        } catch {
            throw SpotifyAuthorizationError.invalidTokenResponse
        }
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct TokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}
