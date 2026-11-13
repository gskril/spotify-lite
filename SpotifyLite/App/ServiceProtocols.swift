import Foundation

protocol SpotifyAuthorizing: Sendable {
    func beginAuthorization() async throws
    func validAccessToken() async throws -> String
    /// Forces a refresh even when the cached access token has not expired.
    /// The API client uses this once after a 401 response.
    func refreshAccessToken() async throws -> String
    func signOut() async throws
}

protocol SpotifyAPIProviding: Sendable {
    func currentUser() async throws -> SpotifyUser
    func recentlyPlayed() async throws -> [SpotifyTrack]
    func mostRecentlyPlayed() async throws -> SpotifyTrack?
    func currentUserPlaylists() async throws -> [SpotifyPlaylistSummary]
    func savedTracksPage(after next: URL?) async throws -> Page<SpotifyTrack>
    func savedAlbumsPage(after next: URL?) async throws -> Page<SpotifyAlbumSummary>
    func currentUserPlaylistsPage(after next: URL?) async throws -> Page<SpotifyPlaylistSummary>
    func playlistDetail(for playlist: SpotifyPlaylistSummary) async throws -> SpotifyPlaylistDetail
    func playbackState() async throws -> PlaybackState?
    func playbackQueue() async throws -> PlaybackQueue
    func devices() async throws -> [SpotifyDevice]
    func transferPlayback(to deviceID: String, play: Bool) async throws
    func play(_ request: PlayRequest, on deviceID: String?) async throws
    func pause(on deviceID: String?) async throws
    func next(on deviceID: String?) async throws
    func previous(on deviceID: String?) async throws
    func seek(to milliseconds: Int, on deviceID: String?) async throws
    func setVolume(_ percent: Int, on deviceID: String?) async throws
    func setShuffle(_ enabled: Bool, on deviceID: String?) async throws
    func setRepeat(_ mode: RepeatMode, on deviceID: String?) async throws
    func addToQueue(uri: String, on deviceID: String?) async throws
    func search(_ query: String, types: Set<SearchType>) async throws -> SearchResults
}

extension SpotifyAPIProviding {
    func mostRecentlyPlayed() async throws -> SpotifyTrack? {
        try await recentlyPlayed().first
    }
}

/// Events from the receiver supervisor. The supervisor is the only source of `ReceiverState`:
/// it sends `.stateChanged` for every transition, including failures thrown from `start()`.
///
/// Recovery ordering: before the supervisor replaces a stale receiver it sends
/// `.connectionWillRestart`, so playback holds its snapshot. Once the replacement is running
/// it sends `.connectionInterrupted(restartReceiver: false)`, and only then does playback
/// rediscover the receiver and restore.
enum ReceiverEvent: Sendable, Equatable {
    case stateChanged(ReceiverState)
    case log(String)
    case connectionWillRestart
    case connectionInterrupted(restartReceiver: Bool = false)
    /// Informational. A `.stateChanged` with the resulting state always follows.
    case exited(status: Int32)
}

enum ReceiverState: Sendable, Equatable {
    case notInstalled
    case needsAuthentication
    case stopped
    case starting
    case running(processID: Int32)
    case crashed(status: Int32)
}

struct ReceiverInstallation: Sendable, Equatable {
    let executableURL: URL?
    let version: String?
    /// When this receiver build stops working, if the receiver reports a build date.
    var buildExpiry: Date? = nil
    var isInstalled: Bool { executableURL != nil }
}

protocol ReceiverManaging: Sendable {
    var events: AsyncStream<ReceiverEvent> { get }
    func inspectInstallation() async -> ReceiverInstallation
    func authenticate() async throws
    func start() async throws
    func stop() async
    func startKeepingAlive() async throws
    func stopKeepingAlive() async
}

extension ReceiverManaging {
    func startKeepingAlive() async throws { try await start() }
    func stopKeepingAlive() async { await stop() }
}
