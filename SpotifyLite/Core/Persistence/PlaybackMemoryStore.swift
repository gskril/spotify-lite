import Foundation

struct PlaybackMemoryStore {
    private struct Record: Codable {
        let accountID: String
        let track: SpotifyTrack
        let shuffle: Bool
        let repeatMode: RepeatMode
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

    func save(_ playback: PlaybackState?, for accountID: String) {
        guard let playback, let track = playback.item else { return }
        let record = Record(
            accountID: accountID,
            track: track,
            shuffle: playback.shuffle,
            repeatMode: playback.repeatMode
        )
        guard let data = try? encoder.encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    func load(for accountID: String) -> PlaybackState? {
        guard let data = defaults.data(forKey: key),
              let record = try? decoder.decode(Record.self, from: data),
              record.accountID == accountID else {
            return nil
        }
        return PlaybackState(
            item: record.track,
            progressMS: 0,
            isPlaying: false,
            device: nil,
            shuffle: record.shuffle,
            repeatMode: record.repeatMode
        )
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
