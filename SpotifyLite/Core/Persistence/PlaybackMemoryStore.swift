import Foundation

/// The last playback Spotify Lite saw, and when that track was last known to be current.
struct RememberedPlayback: Sendable, Equatable {
    var playback: PlaybackState
    /// `nil` for records saved before timestamps were stored.
    var savedAt: Date?
}

struct PlaybackMemoryStore {
    private struct Record: Codable {
        let accountID: String
        let track: SpotifyTrack
        let progressMS: Int?
        let shuffle: Bool
        let repeatMode: RepeatMode
        let contextURI: String?
        let savedAt: Date?
    }

    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = "spotify.playback.lastTrack.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// `savedAt` moves forward while the track plays or when a different track is saved. A
    /// paused track keeps its earlier time, so restoring it at launch does not make it look
    /// newer than what the account played elsewhere since.
    func save(_ playback: PlaybackState?, for accountID: String, now: Date = Date()) {
        guard let playback, let track = playback.item else { return }
        var savedAt = now
        if !playback.isPlaying,
           let previous = record(),
           previous.accountID == accountID,
           previous.track.uri == track.uri,
           let previousSavedAt = previous.savedAt {
            savedAt = previousSavedAt
        }
        let record = Record(
            accountID: accountID,
            track: track,
            progressMS: min(max(0, playback.progressMS), track.durationMS),
            shuffle: playback.shuffle,
            repeatMode: playback.repeatMode,
            contextURI: playback.contextURI,
            savedAt: savedAt
        )
        guard let data = try? encoder.encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    func load(for accountID: String) -> RememberedPlayback? {
        guard let record = record(), record.accountID == accountID else { return nil }
        let playback = PlaybackState(
            item: record.track,
            progressMS: min(max(0, record.progressMS ?? 0), record.track.durationMS),
            isPlaying: false,
            device: nil,
            shuffle: record.shuffle,
            repeatMode: record.repeatMode,
            contextURI: record.contextURI
        )
        return RememberedPlayback(playback: playback, savedAt: record.savedAt)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    private func record() -> Record? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(Record.self, from: data)
    }
}
