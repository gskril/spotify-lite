import Foundation
import XCTest
@testable import SpotifyLite

final class SpotifyAPIClientTests: XCTestCase {
    override func tearDown() {
        APIURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testCurrentUserAddsBearerTokenAndDecodesResponse() async throws {
        let recorder = APIRequestRecorder(responses: [
            .init(status: 200, body: #"{"id":"test-user","display_name":"Test User","product":"premium"}"#)
        ])
        APIURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let api = makeAPI(authorizer: APIMockAuthorizer(token: "access-token"))

        let user = try await api.currentUser()

        XCTAssertEqual(user.id, "test-user")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/me")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
    }

    func testSearchUsesStableTypeOrderAnd2026Limit() async throws {
        let recorder = APIRequestRecorder(responses: [
            .init(status: 200, body: #"{"tracks":{"items":[],"next":null},"artists":{"items":[],"next":null}}"#)
        ])
        APIURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let api = makeAPI(authorizer: APIMockAuthorizer(token: "token"))

        _ = try await api.search("massive attack", types: [.track, .artist])

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(recorder.requests.first?.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(components.path, "/v1/search")
        XCTAssertEqual(query["q"], "massive attack")
        XCTAssertEqual(query["type"], "artist,track")
        XCTAssertEqual(query["limit"], "10")
    }

    func testQuotaExceededIsDistinctAndNeverRetried() async throws {
        let recorder = APIRequestRecorder(responses: [
            .init(
                status: 429,
                headers: ["Retry-After": "1"],
                body: #"{"error":{"status":429,"message":"Developer quota reached","reason":"QUOTA_EXCEEDED"}}"#
            )
        ])
        APIURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let sleepRecorder = APISleepRecorder()
        let api = makeAPI(
            authorizer: APIMockAuthorizer(token: "token"),
            sleeper: { await sleepRecorder.record($0) }
        )

        do {
            _ = try await api.currentUser()
            XCTFail("Expected quotaExceeded")
        } catch let error as SpotifyAPIError {
            XCTAssertEqual(error, .quotaExceeded(message: "Developer quota reached"))
        }
        XCTAssertEqual(recorder.requests.count, 1)
        let recordedSleeps = await sleepRecorder.values
        XCTAssertEqual(recordedSleeps, [])
    }

    func testReadRateLimitHonorsRetryAfterThenRetries() async throws {
        let recorder = APIRequestRecorder(responses: [
            .init(status: 429, headers: ["Retry-After": "2"], body: #"{"error":{"status":429,"message":"Slow down"}}"#),
            .init(status: 200, body: #"{"id":"test-user"}"#)
        ])
        APIURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let sleepRecorder = APISleepRecorder()
        let api = makeAPI(
            authorizer: APIMockAuthorizer(token: "token"),
            sleeper: { await sleepRecorder.record($0) }
        )

        _ = try await api.currentUser()

        XCTAssertEqual(recorder.requests.count, 2)
        let recordedSleeps = await sleepRecorder.values
        XCTAssertEqual(recordedSleeps, [2])
    }

    func testMutationRateLimitIsNotRetried() async throws {
        let recorder = APIRequestRecorder(responses: [
            .init(status: 429, headers: ["Retry-After": "3"], body: #"{"error":{"status":429,"message":"Slow down"}}"#)
        ])
        APIURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let api = makeAPI(authorizer: APIMockAuthorizer(token: "token"))

        do {
            try await api.pause(on: "device")
            XCTFail("Expected rateLimited")
        } catch let error as SpotifyAPIError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 3, message: "Slow down"))
        }
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testUnauthorizedResponseForcesOneRefreshAndRetriesOnce() async throws {
        let recorder = APIRequestRecorder { request, index in
            if index == 0 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old")
                return .init(status: 401, body: #"{"error":{"status":401,"message":"Expired"}}"#)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new")
            return .init(status: 200, body: #"{"id":"test-user"}"#)
        }
        APIURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let authorizer = APIMockAuthorizer(token: "old", refreshedToken: "new")
        let api = makeAPI(authorizer: authorizer)

        _ = try await api.currentUser()

        let refreshCount = await authorizer.refreshCount
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testSavedTracksFollowsNextAndSkipsMalformedItems() async throws {
        let pageOne = #"{"items":[{"track":{"id":"one","name":"One","uri":"spotify:track:one","duration_ms":100,"explicit":false,"artists":[]}},null],"next":"https://unit.test/v1/me/tracks?offset=2"}"#
        let pageTwo = #"{"items":[{"track":{"id":"two","name":"Two","uri":"spotify:track:two","duration_ms":200,"explicit":false,"artists":[]}}],"next":null}"#
        let recorder = APIRequestRecorder(responses: [
            .init(status: 200, body: pageOne),
            .init(status: 200, body: pageTwo)
        ])
        APIURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let api = makeAPI(authorizer: APIMockAuthorizer(token: "token"))

        let tracks = try await api.savedTracks()

        XCTAssertEqual(tracks.map(\.id), ["one", "two"])
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(recorder.requests.last?.url?.query, "offset=2")
    }

    func testLibraryMutationUsesNewUnifiedEndpointAndSpotifyURI() async throws {
        let recorder = APIRequestRecorder(responses: [.init(status: 200, body: "")])
        APIURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let api = makeAPI(authorizer: APIMockAuthorizer(token: "token"))

        try await api.setSaved(trackID: "abc", saved: false)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v1/me/library")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "spotify:track:abc")
    }

    func testPlaylistDetailLoadsMetadataAndAllItemPagesLossTolerantly() async throws {
        let detail = #"{"id":"playlist","name":"Updated name","uri":"spotify:playlist:playlist","description":"Detail description","images":[],"items":{"items":[{"item":{"id":"one","name":"One","uri":"spotify:track:one","duration_ms":100,"explicit":false,"artists":[]}},null,{"item":null}],"next":"https://unit.test/v1/playlists/playlist/items?offset=3"}}"#
        let nextPage = #"{"items":[{"item":{"id":"two","name":"Two","uri":"spotify:track:two","duration_ms":200,"explicit":false,"artists":[]}},"unavailable"],"next":null}"#
        let recorder = APIRequestRecorder(responses: [
            .init(status: 200, body: detail),
            .init(status: 200, body: nextPage)
        ])
        APIURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let api = makeAPI(authorizer: APIMockAuthorizer(token: "token"))

        let result = try await api.playlistDetail(for: playlistSummary())

        XCTAssertEqual(result.itemAccess, .available)
        XCTAssertEqual(result.summary.name, "Updated name")
        XCTAssertEqual(result.summary.description, "Detail description")
        XCTAssertEqual(result.tracks.map(\.id), ["one", "two"])
        XCTAssertEqual(recorder.requests.map { $0.url?.path }, [
            "/v1/playlists/playlist",
            "/v1/playlists/playlist/items"
        ])
    }

    func testPlaylistDetailReturnsRestrictedStateForDevelopmentMode403() async throws {
        let recorder = APIRequestRecorder(responses: [
            .init(status: 403, body: #"{"error":{"status":403,"message":"Only owned or collaborative playlists are available"}}"#)
        ])
        APIURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let api = makeAPI(authorizer: APIMockAuthorizer(token: "token"))
        let summary = playlistSummary()

        let result = try await api.playlistDetail(for: summary)

        XCTAssertEqual(result.summary, summary)
        XCTAssertEqual(result.tracks, [])
        XCTAssertEqual(result.itemAccess, .restricted)
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testPlaylistDetailWithoutItemsReturnsRestrictedMetadata() async throws {
        let recorder = APIRequestRecorder(responses: [
            .init(status: 200, body: #"{"id":"playlist","name":"Visible metadata","uri":"spotify:playlist:playlist","images":[]}"#)
        ])
        APIURLProtocolStub.handler = { try recorder.respond(to: $0) }
        let api = makeAPI(authorizer: APIMockAuthorizer(token: "token"))

        let result = try await api.playlistDetail(for: playlistSummary())

        XCTAssertEqual(result.summary.name, "Visible metadata")
        XCTAssertEqual(result.itemAccess, .restricted)
    }

    private func makeAPI(
        authorizer: some SpotifyAuthorizing,
        sleeper: @escaping SpotifyAPIClient.Sleeper = { _ in }
    ) -> SpotifyAPIClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [APIURLProtocolStub.self]
        let session = URLSession(configuration: sessionConfiguration)
        var configuration = SpotifyAPIClient.Configuration()
        configuration.baseURL = URL(string: "https://unit.test/v1/")!
        configuration.maximumRateLimitRetries = 2
        return SpotifyAPIClient(
            authorizer: authorizer,
            session: session,
            configuration: configuration,
            sleeper: sleeper,
            jitter: { 0 }
        )
    }

    private func playlistSummary() -> SpotifyPlaylistSummary {
        SpotifyPlaylistSummary(
            id: "playlist",
            name: "Fallback name",
            uri: "spotify:playlist:playlist",
            description: "Fallback description",
            images: []
        )
    }
}

private actor APIMockAuthorizer: SpotifyAccessTokenRefreshing {
    private var token: String
    private let refreshedToken: String
    private(set) var refreshCount = 0

    init(token: String, refreshedToken: String = "refreshed") {
        self.token = token
        self.refreshedToken = refreshedToken
    }

    func beginAuthorization() async throws {}
    func validAccessToken() async throws -> String { token }
    func signOut() async throws {}

    func refreshAccessToken() async throws -> String {
        refreshCount += 1
        token = refreshedToken
        return refreshedToken
    }
}

private actor APISleepRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}

private struct APIStubResponse: Sendable {
    let status: Int
    var headers: [String: String] = [:]
    let body: String
}

private final class APIRequestRecorder: @unchecked Sendable {
    typealias Responder = @Sendable (URLRequest, Int) throws -> APIStubResponse

    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private let responder: Responder

    init(responses: [APIStubResponse]) {
        self.responder = { _, index in
            guard responses.indices.contains(index) else { throw URLError(.badServerResponse) }
            return responses[index]
        }
    }

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    func respond(to request: URLRequest) throws -> APIStubResponse {
        let index = lock.withLock {
            let index = storedRequests.count
            storedRequests.append(request)
            return index
        }
        return try responder(request, index)
    }
}

private final class APIURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> APIStubResponse)?

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
