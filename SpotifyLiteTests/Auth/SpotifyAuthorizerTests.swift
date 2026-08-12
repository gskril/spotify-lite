import Foundation
import XCTest
@testable import SpotifyLite

final class SpotifyAuthorizerTests: XCTestCase {
    override func tearDown() {
        AuthURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testPKCEChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierAndStateUseURLSafeAlphabet() throws {
        let verifier = try PKCE.verifier()
        let state = try PKCE.state()

        XCTAssertTrue((43...128).contains(verifier.count))
        XCTAssertGreaterThanOrEqual(state.count, 32)
        XCTAssertNil(verifier.range(of: #"[^A-Za-z0-9_-]"#, options: .regularExpression))
        XCTAssertNil(state.range(of: #"[^A-Za-z0-9_-]"#, options: .regularExpression))
    }

    func testAuthorizationURLUsesLoopbackRedirectPKCEAndMinimalScopes() throws {
        let redirect = URL(string: "http://127.0.0.1:54321/callback")!
        let url = try SpotifyAuthorizer.makeAuthorizationURL(
            endpoint: URL(string: "https://accounts.spotify.com/authorize")!,
            clientID: "client",
            redirectURI: redirect,
            scopes: SpotifyAuthorizer.Configuration().scopes,
            state: "state",
            challenge: "challenge"
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(query["redirect_uri"], redirect.absoluteString)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["code_challenge"], "challenge")
        XCTAssertEqual(query["state"], "state")
        XCTAssertFalse(query["scope", default: ""].contains("user-top-read"))
        XCTAssertFalse(query["scope", default: ""].contains("user-read-email"))
    }

    func testCallbackRequiresMatchingStateBeforeReturningCode() throws {
        let callback = URL(string: "http://127.0.0.1:1234/callback?code=secret&state=wrong")!
        XCTAssertThrowsError(try SpotifyAuthorizer.authorizationCode(from: callback, expectedState: "expected")) { error in
            XCTAssertEqual(error as? SpotifyAuthorizationError, .stateMismatch)
        }
    }

    func testBeginAuthorizationExchangesCodeWithRuntimeRedirectAndPersistsTokens() async throws {
        let redirect = URL(string: "http://127.0.0.1:54321/callback")!
        let flow = AuthFlowState(redirectURI: redirect)
        let store = AuthMemoryTokenStore()
        let recorder = AuthRequestRecorder(response: .init(
            status: 200,
            body: #"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"scope":"user-library-read"}"#
        ))
        AuthURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let authorizer = SpotifyAuthorizer(
            clientID: "client-id",
            tokenStore: store,
            callbackListener: AuthMockCallbackListener(flow: flow),
            urlOpener: AuthMockURLOpener(flow: flow),
            session: makeSession(),
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        try await authorizer.beginAuthorization()

        let storedAfterAuthorization = await store.tokens
        let saved = try XCTUnwrap(storedAfterAuthorization)
        XCTAssertEqual(saved.accessToken, "access")
        XCTAssertEqual(saved.refreshToken, "refresh")
        XCTAssertEqual(saved.expiresAt, Date(timeIntervalSince1970: 4_600))
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        let form = formValues(from: request)
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["client_id"], "client-id")
        XCTAssertEqual(form["redirect_uri"], redirect.absoluteString)
        XCTAssertNotNil(form["code_verifier"])
        XCTAssertEqual(form["code"], "authorization-code")
    }

    func testConcurrentRefreshesAreCoalescedAndPreserveRefreshToken() async throws {
        let store = AuthMemoryTokenStore(tokens: OAuthTokens(
            accessToken: "expired",
            refreshToken: "long-lived-refresh",
            expiresAt: .distantPast,
            scope: "user-library-read"
        ))
        let recorder = AuthRequestRecorder(
            response: .init(status: 200, body: #"{"access_token":"new-access","expires_in":3600}"#),
            responseDelay: 0.1
        )
        AuthURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let authorizer = SpotifyAuthorizer(
            clientID: "client-id",
            tokenStore: store,
            session: makeSession(),
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let tokens = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<12 {
                group.addTask { try await authorizer.refreshAccessToken() }
            }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(Set(tokens), ["new-access"])
        XCTAssertEqual(recorder.requests.count, 1)
        let storedAfterRefresh = await store.tokens
        XCTAssertEqual(storedAfterRefresh?.refreshToken, "long-lived-refresh")
    }

    func testRejectedRefreshDeletesCredentialsAndRequiresReauthorization() async throws {
        let store = AuthMemoryTokenStore(tokens: OAuthTokens(
            accessToken: "expired",
            refreshToken: "rejected",
            expiresAt: .distantPast,
            scope: nil
        ))
        let recorder = AuthRequestRecorder(response: .init(
            status: 400,
            body: #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#
        ))
        AuthURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let authorizer = SpotifyAuthorizer(
            clientID: "client-id",
            tokenStore: store,
            session: makeSession()
        )

        do {
            _ = try await authorizer.validAccessToken()
            XCTFail("Expected refresh rejection")
        } catch let error as SpotifyAuthorizationError {
            XCTAssertEqual(error, .tokenRejected(code: "invalid_grant", message: "Refresh token revoked"))
        }
        let storedAfterRejection = await store.tokens
        XCTAssertNil(storedAfterRejection)
    }

    func testLoopbackListenerUsesDashboardCompatiblePortAndReturnsCallback() async throws {
        let receiver = try await LoopbackOAuthCallbackListener().start(callbackPath: "/callback")
        defer { receiver.cancel() }
        XCTAssertEqual(receiver.redirectURI.host, "127.0.0.1")
        XCTAssertEqual(receiver.redirectURI.port, 43_821)

        var components = try XCTUnwrap(URLComponents(url: receiver.redirectURI, resolvingAgainstBaseURL: false))
        components.queryItems = [
            URLQueryItem(name: "code", value: "code"),
            URLQueryItem(name: "state", value: "state")
        ]
        let callbackURL = try XCTUnwrap(components.url)
        async let received = receiver.waitForCallback()
        let (_, response) = try await URLSession.shared.data(from: callbackURL)
        let returned = try await received

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(returned, callbackURL)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func formValues(from request: URLRequest) -> [String: String] {
        guard let body = request.httpBody.flatMap({ String(data: $0, encoding: .utf8) }) else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = body
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}

private actor AuthMemoryTokenStore: OAuthTokenStoring {
    private(set) var tokens: OAuthTokens?

    init(tokens: OAuthTokens? = nil) {
        self.tokens = tokens
    }

    func load() async throws -> OAuthTokens? { tokens }
    func save(_ tokens: OAuthTokens) async throws { self.tokens = tokens }
    func delete() async throws { tokens = nil }
}

private actor AuthFlowState {
    let redirectURI: URL
    private var callbackURL: URL?

    init(redirectURI: URL) {
        self.redirectURI = redirectURI
    }

    func browserOpened(_ authorizationURL: URL) throws {
        let components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
        guard let state = components?.queryItems?.first(where: { $0.name == "state" })?.value else {
            throw SpotifyAuthorizationError.callbackFailed("State was missing from the authorization request.")
        }
        var callback = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)
        callback?.queryItems = [
            URLQueryItem(name: "code", value: "authorization-code"),
            URLQueryItem(name: "state", value: state)
        ]
        callbackURL = callback?.url
    }

    func callback() throws -> URL {
        guard let callbackURL else {
            throw SpotifyAuthorizationError.callbackFailed("The mock browser was not opened.")
        }
        return callbackURL
    }
}

private struct AuthMockCallbackListener: OAuthCallbackListening {
    let flow: AuthFlowState

    func start(callbackPath: String) async throws -> OAuthCallbackReceiver {
        let redirectURI = flow.redirectURI
        return OAuthCallbackReceiver(
            redirectURI: redirectURI,
            wait: { try await flow.callback() },
            cancel: {}
        )
    }
}

private struct AuthMockURLOpener: AuthorizationURLOpening {
    let flow: AuthFlowState
    func open(_ url: URL) async throws { try await flow.browserOpened(url) }
}

private struct AuthStubResponse: Sendable {
    let status: Int
    var headers: [String: String] = [:]
    let body: String
}

private final class AuthRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private let response: AuthStubResponse
    private let responseDelay: TimeInterval

    init(response: AuthStubResponse, responseDelay: TimeInterval = 0) {
        self.response = response
        self.responseDelay = responseDelay
    }

    var requests: [URLRequest] { lock.withLock { storedRequests } }

    func respond(to request: URLRequest) throws -> AuthStubResponse {
        let recordedRequest = request.materializingBodyStream()
        lock.withLock { storedRequests.append(recordedRequest) }
        if responseDelay > 0 { Thread.sleep(forTimeInterval: responseDelay) }
        return response
    }
}

private extension URLRequest {
    func materializingBodyStream() -> URLRequest {
        guard httpBody == nil, let stream = httpBodyStream else { return self }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        var copy = self
        copy.httpBodyStream = nil
        copy.httpBody = data
        return copy
    }
}

private final class AuthURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> AuthStubResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let stub = try handler(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
            else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
