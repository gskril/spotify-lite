import Foundation

enum PlaceholderError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        "Finish setup to connect Spotify."
    }
}

actor PlaceholderAuthorizer: SpotifyAuthorizing {
    func beginAuthorization() async throws { throw PlaceholderError.notConfigured }
    func validAccessToken() async throws -> String { throw PlaceholderError.notConfigured }
    func signOut() async throws {}
}

actor PlaceholderAPI: SpotifyAPIProviding {
    func currentUser() async throws -> SpotifyUser { throw PlaceholderError.notConfigured }
    func recentlyPlayed() async throws -> [SpotifyTrack] { [] }
    func savedTracks() async throws -> [SpotifyTrack] { [] }
    func savedAlbums() async throws -> [SpotifyAlbumSummary] { [] }
    func currentUserPlaylists() async throws -> [SpotifyPlaylistSummary] { [] }
    func playlistDetail(for playlist: SpotifyPlaylistSummary) async throws -> SpotifyPlaylistDetail {
        SpotifyPlaylistDetail(summary: playlist, tracks: [], itemAccess: .restricted)
    }
    func playbackState() async throws -> PlaybackState? { nil }
    func playbackQueue() async throws -> PlaybackQueue { .init(currentlyPlaying: nil, upcoming: []) }
    func devices() async throws -> [SpotifyDevice] { [] }
    func transferPlayback(to deviceID: String, play: Bool) async throws { throw PlaceholderError.notConfigured }
    func play(_ request: PlayRequest, on deviceID: String?) async throws { throw PlaceholderError.notConfigured }
    func pause(on deviceID: String?) async throws { throw PlaceholderError.notConfigured }
    func next(on deviceID: String?) async throws { throw PlaceholderError.notConfigured }
    func previous(on deviceID: String?) async throws { throw PlaceholderError.notConfigured }
    func seek(to milliseconds: Int, on deviceID: String?) async throws { throw PlaceholderError.notConfigured }
    func setVolume(_ percent: Int, on deviceID: String?) async throws { throw PlaceholderError.notConfigured }
    func setShuffle(_ enabled: Bool, on deviceID: String?) async throws { throw PlaceholderError.notConfigured }
    func setRepeat(_ mode: RepeatMode, on deviceID: String?) async throws { throw PlaceholderError.notConfigured }
    func addToQueue(uri: String, on deviceID: String?) async throws { throw PlaceholderError.notConfigured }
    func search(_ query: String, types: Set<SearchType>) async throws -> SearchResults { .init() }
    func setSaved(trackID: String, saved: Bool) async throws { throw PlaceholderError.notConfigured }
}

actor PlaceholderSpotifydManager: SpotifydManaging {
    nonisolated let events = AsyncStream<SpotifydEvent> { $0.finish() }
    func inspectInstallation() async -> SpotifydInstallation { .init(executableURL: nil, version: nil) }
    func authenticate() async throws { throw PlaceholderError.notConfigured }
    func start() async throws { throw PlaceholderError.notConfigured }
    func stop() async {}
}
