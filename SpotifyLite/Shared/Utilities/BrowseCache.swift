import Foundation

/// A value loaded from Spotify, with the time it arrived.
struct Cached<Value> {
    var value: Value
    var storedAt: Date

    init(_ value: Value, storedAt: Date = .now) {
        self.value = value
        self.storedAt = storedAt
    }

    func isFresh(at now: Date = .now) -> Bool {
        now.timeIntervalSince(storedAt) < BrowseCache.freshness
    }
}

struct HomeSnapshot {
    var recentTracks: [SpotifyTrack]
    var playlists: [SpotifyPlaylistSummary]
}

struct LibrarySnapshot {
    var tracks: [SpotifyTrack] = []
    var albums: [SpotifyAlbumSummary] = []
    var playlists: [SpotifyPlaylistSummary] = []
    var nextPages: [LibraryView.Section: URL] = [:]
    var loadedAt: [LibraryView.Section: Date] = [:]
}

/// Keeps Home and Library data for the signed-in session so switching destinations shows
/// it at once. Data younger than `freshness` is reused without a request; older data stays
/// visible while the view refreshes it. Memory only, and cleared when the session ends.
@MainActor
final class BrowseCache {
    nonisolated static let freshness: TimeInterval = 15 * 60

    var home: Cached<HomeSnapshot>?
    var library = LibrarySnapshot()

    func isLibrarySectionFresh(_ section: LibraryView.Section, at now: Date = .now) -> Bool {
        guard let loadedAt = library.loadedAt[section] else { return false }
        return now.timeIntervalSince(loadedAt) < Self.freshness
    }

    func clear() {
        home = nil
        library = LibrarySnapshot()
    }
}
