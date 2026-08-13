import Foundation

actor SpotifyAPIClient: SpotifyAPIProviding {
    struct Configuration: Sendable {
        var baseURL = URL(string: "https://api.spotify.com/v1/")!
        var maximumRateLimitRetries = 2
        var maximumRetryDelay: TimeInterval = 30
        var maximumPages = 1_000
    }

    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let authorizer: any SpotifyAuthorizing
    private let session: URLSession
    private let configuration: Configuration
    private let sleeper: Sleeper
    private let jitter: @Sendable () -> TimeInterval
    private let decoder: JSONDecoder

    init(
        authorizer: any SpotifyAuthorizing,
        session: URLSession = .shared,
        configuration: Configuration = .init(),
        sleeper: @escaping Sleeper = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        jitter: @escaping @Sendable () -> TimeInterval = { Double.random(in: 0...0.25) }
    ) {
        self.authorizer = authorizer
        self.session = session
        self.configuration = configuration
        self.sleeper = sleeper
        self.jitter = jitter
        self.decoder = JSONDecoder()
    }

    func currentUser() async throws -> SpotifyUser {
        try await decode(SpotifyUser.self, from: Endpoint(method: "GET", path: "me"))
    }

    func recentlyPlayed() async throws -> [SpotifyTrack] {
        try await collect(
            first: Endpoint(
                method: "GET",
                path: "me/player/recently-played",
                query: [URLQueryItem(name: "limit", value: "50")]
            ),
            as: LossTolerant<RecentlyPlayedItem>.self,
            transform: { $0.value?.track }
        )
    }

    func mostRecentlyPlayed() async throws -> SpotifyTrack? {
        let page = try await decode(
            SpotifyPage<LossTolerant<RecentlyPlayedItem>>.self,
            from: Endpoint(
                method: "GET",
                path: "me/player/recently-played",
                query: [URLQueryItem(name: "limit", value: "1")]
            )
        )
        return page.items.first?.value?.track
    }

    func savedTracks() async throws -> [SpotifyTrack] {
        try await collect(
            first: Endpoint(
                method: "GET",
                path: "me/tracks",
                query: [URLQueryItem(name: "limit", value: "50")]
            ),
            as: LossTolerant<SavedTrackItem>.self,
            transform: { $0.value?.track }
        )
    }

    func savedTracksPage(after next: URL?) async throws -> Page<SpotifyTrack> {
        try await collectPage(
            first: Endpoint(
                method: "GET",
                path: "me/tracks",
                query: [URLQueryItem(name: "limit", value: "50")]
            ),
            after: next,
            as: LossTolerant<SavedTrackItem>.self,
            transform: { $0.value?.track }
        )
    }

    func savedAlbums() async throws -> [SpotifyAlbumSummary] {
        try await collect(
            first: Endpoint(
                method: "GET",
                path: "me/albums",
                query: [URLQueryItem(name: "limit", value: "50")]
            ),
            as: LossTolerant<SavedAlbumItem>.self,
            transform: { $0.value?.album }
        )
    }

    func savedAlbumsPage(after next: URL?) async throws -> Page<SpotifyAlbumSummary> {
        try await collectPage(
            first: Endpoint(
                method: "GET",
                path: "me/albums",
                query: [URLQueryItem(name: "limit", value: "50")]
            ),
            after: next,
            as: LossTolerant<SavedAlbumItem>.self,
            transform: { $0.value?.album }
        )
    }

    func currentUserPlaylists() async throws -> [SpotifyPlaylistSummary] {
        try await collect(
            first: Endpoint(
                method: "GET",
                path: "me/playlists",
                query: [URLQueryItem(name: "limit", value: "50")]
            ),
            as: LossTolerant<SpotifyPlaylistSummary>.self,
            transform: { $0.value }
        )
    }

    func currentUserPlaylistsPage(after next: URL?) async throws -> Page<SpotifyPlaylistSummary> {
        try await collectPage(
            first: Endpoint(
                method: "GET",
                path: "me/playlists",
                query: [URLQueryItem(name: "limit", value: "50")]
            ),
            after: next,
            as: LossTolerant<SpotifyPlaylistSummary>.self,
            transform: { $0.value }
        )
    }

    func playlistDetail(for playlist: SpotifyPlaylistSummary) async throws -> SpotifyPlaylistDetail {
        guard !playlist.id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("A playlist ID is required.")
        }

        let response: PlaylistDetailResponse
        do {
            response = try await decode(
                PlaylistDetailResponse.self,
                from: Endpoint(method: "GET", path: "playlists/\(playlist.id)")
            )
        } catch SpotifyAPIError.forbidden {
            return SpotifyPlaylistDetail(summary: playlist, tracks: [], itemAccess: .restricted)
        }

        let summary = response.summary(fallingBackTo: playlist)
        guard let firstPage = response.items else {
            return SpotifyPlaylistDetail(summary: summary, tracks: [], itemAccess: .restricted)
        }

        var tracks = firstPage.items.compactMap { $0.value?.track }
        var next = firstPage.next.flatMap(URL.init(string:))
        var visited = Set<URL>()
        var pageCount = 1

        while let pageURL = next {
            try Task.checkCancellation()
            guard visited.insert(pageURL).inserted else {
                throw SpotifyAPIError.paginationLimitExceeded
            }
            pageCount += 1
            guard pageCount <= configuration.maximumPages else {
                throw SpotifyAPIError.paginationLimitExceeded
            }

            let page = try await decode(
                SpotifyPage<LossTolerant<PlaylistItemResponse>>.self,
                from: Endpoint(method: "GET", absoluteURL: pageURL)
            )
            tracks.append(contentsOf: page.items.compactMap { $0.value?.track })
            next = page.next.flatMap(URL.init(string:))
        }

        return SpotifyPlaylistDetail(summary: summary, tracks: tracks, itemAccess: .available)
    }

    func playbackState() async throws -> PlaybackState? {
        let endpoint = Endpoint(method: "GET", path: "me/player")
        let data = try await requestData(endpoint)
        if data.isEmpty { return nil }
        do {
            return try decoder.decode(PlaybackResponse.self, from: data).domainModel
        } catch {
            throw SpotifyAPIError.decoding("Spotify playback state could not be read.")
        }
    }

    func playbackQueue() async throws -> PlaybackQueue {
        let response = try await decode(
            PlaybackQueueResponse.self,
            from: Endpoint(method: "GET", path: "me/player/queue")
        )
        return PlaybackQueue(
            currentlyPlaying: response.currentlyPlaying?.value,
            upcoming: response.queue.compactMap(\.value)
        )
    }

    func devices() async throws -> [SpotifyDevice] {
        try await decode(DevicesResponse.self, from: Endpoint(method: "GET", path: "me/player/devices")).devices
    }

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        guard !deviceID.isEmpty else { throw SpotifyAPIError.invalidRequest("A playback device is required.") }
        let body = try encode(TransferPlaybackBody(deviceIDs: [deviceID], play: play))
        try await send(Endpoint(method: "PUT", path: "me/player", body: body, isMutation: true))
    }

    func play(_ request: PlayRequest, on deviceID: String?) async throws {
        let body: Data?
        switch request {
        case .resume:
            body = nil
        case .uris(let uris, let offset):
            guard !uris.isEmpty else { throw SpotifyAPIError.invalidRequest("At least one track is required.") }
            if let offset, offset < 0 { throw SpotifyAPIError.invalidRequest("The playback offset cannot be negative.") }
            body = try encode(StartPlaybackBody(
                contextURI: nil,
                uris: uris,
                offset: offset.map { .init(position: $0, uri: nil) }
            ))
        case .context(let uri, let offsetURI):
            guard !uri.isEmpty else { throw SpotifyAPIError.invalidRequest("A playback context is required.") }
            body = try encode(StartPlaybackBody(
                contextURI: uri,
                uris: nil,
                offset: offsetURI.map { .init(position: nil, uri: $0) }
            ))
        }
        try await send(Endpoint(
            method: "PUT",
            path: "me/player/play",
            query: deviceQuery(deviceID),
            body: body,
            isMutation: true
        ))
    }

    func pause(on deviceID: String?) async throws {
        try await playbackCommand(method: "PUT", path: "me/player/pause", deviceID: deviceID)
    }

    func next(on deviceID: String?) async throws {
        try await playbackCommand(method: "POST", path: "me/player/next", deviceID: deviceID)
    }

    func previous(on deviceID: String?) async throws {
        try await playbackCommand(method: "POST", path: "me/player/previous", deviceID: deviceID)
    }

    func seek(to milliseconds: Int, on deviceID: String?) async throws {
        guard milliseconds >= 0 else { throw SpotifyAPIError.invalidRequest("The seek position cannot be negative.") }
        var query = [URLQueryItem(name: "position_ms", value: String(milliseconds))]
        query.append(contentsOf: deviceQuery(deviceID))
        try await send(Endpoint(method: "PUT", path: "me/player/seek", query: query, isMutation: true))
    }

    func setVolume(_ percent: Int, on deviceID: String?) async throws {
        guard (0...100).contains(percent) else {
            throw SpotifyAPIError.invalidRequest("Volume must be between 0 and 100 percent.")
        }
        var query = [URLQueryItem(name: "volume_percent", value: String(percent))]
        query.append(contentsOf: deviceQuery(deviceID))
        try await send(Endpoint(method: "PUT", path: "me/player/volume", query: query, isMutation: true))
    }

    func setShuffle(_ enabled: Bool, on deviceID: String?) async throws {
        var query = [URLQueryItem(name: "state", value: String(enabled))]
        query.append(contentsOf: deviceQuery(deviceID))
        try await send(Endpoint(method: "PUT", path: "me/player/shuffle", query: query, isMutation: true))
    }

    func setRepeat(_ mode: RepeatMode, on deviceID: String?) async throws {
        var query = [URLQueryItem(name: "state", value: mode.rawValue)]
        query.append(contentsOf: deviceQuery(deviceID))
        try await send(Endpoint(method: "PUT", path: "me/player/repeat", query: query, isMutation: true))
    }

    func addToQueue(uri: String, on deviceID: String?) async throws {
        guard !uri.isEmpty else { throw SpotifyAPIError.invalidRequest("A Spotify item URI is required.") }
        var query = [URLQueryItem(name: "uri", value: uri)]
        query.append(contentsOf: deviceQuery(deviceID))
        try await send(Endpoint(method: "POST", path: "me/player/queue", query: query, isMutation: true))
    }

    func search(_ query: String, types: Set<SearchType>) async throws -> SearchResults {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !types.isEmpty else { return SearchResults() }
        let typeList = types.map(\.rawValue).sorted().joined(separator: ",")
        let response = try await decode(SearchResponse.self, from: Endpoint(
            method: "GET",
            path: "search",
            query: [
                URLQueryItem(name: "q", value: trimmedQuery),
                URLQueryItem(name: "type", value: typeList),
                URLQueryItem(name: "limit", value: "10")
            ]
        ))
        return SearchResults(
            tracks: response.tracks?.items.compactMap(\.value) ?? [],
            albums: response.albums?.items.compactMap(\.value) ?? [],
            artists: response.artists?.items.compactMap(\.value) ?? [],
            playlists: response.playlists?.items.compactMap(\.value) ?? []
        )
    }

    func setSaved(trackID: String, saved: Bool) async throws {
        guard !trackID.isEmpty else { throw SpotifyAPIError.invalidRequest("A track ID is required.") }
        try await send(Endpoint(
            method: saved ? "PUT" : "DELETE",
            path: "me/library",
            query: [URLQueryItem(name: "uris", value: "spotify:track:\(trackID)")],
            isMutation: true
        ))
    }

    private func playbackCommand(method: String, path: String, deviceID: String?) async throws {
        try await send(Endpoint(
            method: method,
            path: path,
            query: deviceQuery(deviceID),
            isMutation: true
        ))
    }

    private func deviceQuery(_ deviceID: String?) -> [URLQueryItem] {
        guard let deviceID, !deviceID.isEmpty else { return [] }
        return [URLQueryItem(name: "device_id", value: deviceID)]
    }

    private func send(_ endpoint: Endpoint) async throws {
        _ = try await requestData(endpoint)
    }

    private func decode<Value: Decodable & Sendable>(_ type: Value.Type, from endpoint: Endpoint) async throws -> Value {
        let data = try await requestData(endpoint)
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw SpotifyAPIError.decoding("Spotify returned data this version of the app could not read.")
        }
    }

    private func collect<Item: Decodable & Sendable, Output: Sendable>(
        first: Endpoint,
        as itemType: Item.Type,
        transform: @Sendable (Item) -> Output?
    ) async throws -> [Output] {
        var endpoint: Endpoint? = first
        var visited = Set<URL>()
        var output: [Output] = []
        var pageCount = 0

        while let current = endpoint {
            try Task.checkCancellation()
            let currentURL = try makeURL(for: current)
            guard visited.insert(currentURL).inserted else { throw SpotifyAPIError.paginationLimitExceeded }
            pageCount += 1
            guard pageCount <= configuration.maximumPages else { throw SpotifyAPIError.paginationLimitExceeded }

            let page = try await decode(SpotifyPage<Item>.self, from: current)
            output.append(contentsOf: page.items.compactMap(transform))
            if let next = page.next.flatMap(URL.init(string:)) {
                endpoint = Endpoint(method: "GET", absoluteURL: next)
            } else {
                endpoint = nil
            }
        }
        return output
    }

    private func collectPage<Item: Decodable & Sendable, Output: Sendable>(
        first: Endpoint,
        after next: URL?,
        as itemType: Item.Type,
        transform: @Sendable (Item) -> Output?
    ) async throws -> Page<Output> {
        let endpoint = next.map { Endpoint(method: "GET", absoluteURL: $0) } ?? first
        let page = try await decode(SpotifyPage<Item>.self, from: endpoint)
        return Page(
            items: page.items.compactMap(transform),
            next: page.next.flatMap(URL.init(string:))
        )
    }

    private func requestData(_ endpoint: Endpoint) async throws -> Data {
        var token = try await authorizer.validAccessToken()
        var retriedUnauthorized = false
        var rateLimitRetries = 0

        while true {
            try Task.checkCancellation()
            let request = try makeRequest(endpoint, token: token)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.invalidResponse }

            if http.statusCode == 401, !retriedUnauthorized {
                retriedUnauthorized = true
                guard let refreshing = authorizer as? any SpotifyAccessTokenRefreshing else {
                    throw SpotifyAPIError.unauthorized(message: "Spotify authorization expired. Please sign in again.")
                }
                token = try await refreshing.refreshAccessToken()
                continue
            }

            if http.statusCode == 429 {
                let detail = errorDetail(from: data, status: http.statusCode)
                if detail.reason?.uppercased() == "QUOTA_EXCEEDED" {
                    throw SpotifyAPIError.quotaExceeded(
                        message: detail.message ?? "This Spotify app has reached its user quota."
                    )
                }
                let retryAfter = retryAfterSeconds(from: http)
                guard !endpoint.isMutation, rateLimitRetries < configuration.maximumRateLimitRetries else {
                    throw SpotifyAPIError.rateLimited(
                        retryAfter: retryAfter,
                        message: detail.message ?? "Spotify is receiving too many requests. Please try again shortly."
                    )
                }
                let fallback = pow(2, Double(rateLimitRetries))
                let delay = min(configuration.maximumRetryDelay, max(0, retryAfter ?? fallback) + max(0, jitter()))
                rateLimitRetries += 1
                try await sleeper(delay)
                continue
            }

            guard (200..<300).contains(http.statusCode) else {
                throw makeHTTPError(status: http.statusCode, data: data)
            }
            return data
        }
    }

    private func makeRequest(_ endpoint: Endpoint, token: String) throws -> URLRequest {
        let url = try makeURL(for: endpoint)
        guard
            url.scheme?.lowercased() == configuration.baseURL.scheme?.lowercased(),
            url.host?.lowercased() == configuration.baseURL.host?.lowercased()
        else {
            throw SpotifyAPIError.invalidRequest("Spotify returned an unsafe pagination URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.httpBody = endpoint.body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if endpoint.body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func makeURL(for endpoint: Endpoint) throws -> URL {
        let base: URL
        if let absoluteURL = endpoint.absoluteURL {
            base = absoluteURL
        } else {
            base = configuration.baseURL.appending(path: endpoint.path)
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw SpotifyAPIError.invalidRequest("The Spotify request URL was invalid.")
        }
        if !endpoint.query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + endpoint.query
        }
        guard let url = components.url else {
            throw SpotifyAPIError.invalidRequest("The Spotify request URL was invalid.")
        }
        return url
    }

    private func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"), let value = TimeInterval(raw) else {
            return nil
        }
        return max(0, value)
    }

    private func makeHTTPError(status: Int, data: Data) -> SpotifyAPIError {
        let detail = errorDetail(from: data, status: status)
        let message = detail.message ?? "Spotify returned HTTP \(status)."
        switch status {
        case 401:
            return .unauthorized(message: "Spotify authorization expired. Please sign in again.")
        case 403:
            return .forbidden(message: message)
        default:
            return .http(status: status, reason: detail.reason, message: message)
        }
    }

    private func errorDetail(from data: Data, status: Int) -> SpotifyErrorDetail {
        (try? decoder.decode(SpotifyErrorEnvelope.self, from: data).error)
            ?? SpotifyErrorDetail(status: status, message: nil, reason: nil)
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw SpotifyAPIError.invalidRequest("The Spotify request could not be encoded.")
        }
    }
}

private struct Endpoint: Sendable {
    let method: String
    let path: String
    let query: [URLQueryItem]
    let body: Data?
    let isMutation: Bool
    let absoluteURL: URL?

    init(
        method: String,
        path: String = "",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        isMutation: Bool = false,
        absoluteURL: URL? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.isMutation = isMutation
        self.absoluteURL = absoluteURL
    }
}

private struct SpotifyPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let next: String?
}

private struct RecentlyPlayedItem: Decodable, Sendable {
    let track: SpotifyTrack?
}

private struct SavedTrackItem: Decodable, Sendable {
    let track: SpotifyTrack?
}

private struct SavedAlbumItem: Decodable, Sendable {
    let album: SpotifyAlbumSummary?
}

private struct LossTolerant<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct DevicesResponse: Decodable, Sendable {
    let devices: [SpotifyDevice]
}

private struct PlaybackResponse: Decodable, Sendable {
    let device: SpotifyDevice?
    let repeatState: RepeatMode?
    let shuffleState: Bool?
    let isPlaying: Bool?
    let progressMS: Int?
    let item: SpotifyTrack?

    enum CodingKeys: String, CodingKey {
        case device
        case repeatState = "repeat_state"
        case shuffleState = "shuffle_state"
        case isPlaying = "is_playing"
        case progressMS = "progress_ms"
        case item
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try? container.decodeIfPresent(SpotifyDevice.self, forKey: .device)
        repeatState = try? container.decodeIfPresent(RepeatMode.self, forKey: .repeatState)
        shuffleState = try? container.decodeIfPresent(Bool.self, forKey: .shuffleState)
        isPlaying = try? container.decodeIfPresent(Bool.self, forKey: .isPlaying)
        progressMS = try? container.decodeIfPresent(Int.self, forKey: .progressMS)
        item = try? container.decodeIfPresent(SpotifyTrack.self, forKey: .item)
    }

    var domainModel: PlaybackState {
        PlaybackState(
            item: item,
            progressMS: max(0, progressMS ?? 0),
            isPlaying: isPlaying ?? false,
            device: device,
            shuffle: shuffleState ?? false,
            repeatMode: repeatState ?? .off
        )
    }
}

private struct PlaybackQueueResponse: Decodable, Sendable {
    let currentlyPlaying: LossTolerant<SpotifyTrack>?
    let queue: [LossTolerant<SpotifyTrack>]

    enum CodingKeys: String, CodingKey {
        case currentlyPlaying = "currently_playing"
        case queue
    }
}

private struct SearchResponse: Decodable, Sendable {
    let tracks: SpotifyPage<LossTolerant<SpotifyTrack>>?
    let albums: SpotifyPage<LossTolerant<SpotifyAlbumSummary>>?
    let artists: SpotifyPage<LossTolerant<SpotifyArtist>>?
    let playlists: SpotifyPage<LossTolerant<SpotifyPlaylistSummary>>?
}

private struct PlaylistDetailResponse: Decodable, Sendable {
    let id: String?
    let name: String?
    let uri: String?
    let description: String?
    let images: [SpotifyImage]?
    let owner: SpotifyPlaylistOwner?
    let items: SpotifyPage<LossTolerant<PlaylistItemResponse>>?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        uri = try? container.decodeIfPresent(String.self, forKey: .uri)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        images = try? container.decodeIfPresent([SpotifyImage].self, forKey: .images)
        owner = try? container.decodeIfPresent(SpotifyPlaylistOwner.self, forKey: .owner)
        items = try? container.decodeIfPresent(SpotifyPage<LossTolerant<PlaylistItemResponse>>.self, forKey: .items)
    }

    func summary(fallingBackTo fallback: SpotifyPlaylistSummary) -> SpotifyPlaylistSummary {
        SpotifyPlaylistSummary(
            id: id ?? fallback.id,
            name: name ?? fallback.name,
            uri: uri ?? fallback.uri,
            description: description ?? fallback.description,
            images: images ?? fallback.images,
            owner: owner ?? fallback.owner
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, uri, description, images, owner, items
    }
}

private struct PlaylistItemResponse: Decodable, Sendable {
    let track: SpotifyTrack?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `/playlists/{id}/items` uses `item`; accepting `track` keeps decoding
        // loss-tolerant across Spotify's transition from the deprecated shape.
        track = (try? container.decodeIfPresent(SpotifyTrack.self, forKey: .item))
            ?? (try? container.decodeIfPresent(SpotifyTrack.self, forKey: .track))
    }

    private enum CodingKeys: String, CodingKey {
        case item, track
    }
}

private struct SpotifyErrorEnvelope: Decodable, Sendable {
    let error: SpotifyErrorDetail
}

private struct SpotifyErrorDetail: Decodable, Sendable {
    let status: Int?
    let message: String?
    let reason: String?
}

private struct TransferPlaybackBody: Encodable {
    let deviceIDs: [String]
    let play: Bool

    enum CodingKeys: String, CodingKey {
        case deviceIDs = "device_ids"
        case play
    }
}

private struct StartPlaybackBody: Encodable {
    let contextURI: String?
    let uris: [String]?
    let offset: PlaybackOffset?

    enum CodingKeys: String, CodingKey {
        case contextURI = "context_uri"
        case uris, offset
    }
}

private struct PlaybackOffset: Encodable {
    let position: Int?
    let uri: String?
}
