import Foundation

struct SpotifyUser: Codable, Sendable, Equatable {
    let id: String
    let displayName: String?
    let product: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case product
    }
}

struct SpotifyImage: Codable, Sendable, Equatable, Identifiable {
    let url: URL
    let width: Int?
    let height: Int?
    var id: URL { url }
}

struct SpotifyArtist: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let uri: String?
    let images: [SpotifyImage]?
}

struct SpotifyAlbumSummary: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let artists: [SpotifyArtist]
    let images: [SpotifyImage]
    let releaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, name, uri, artists, images
        case releaseDate = "release_date"
    }
}

struct SpotifyTrack: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let durationMS: Int
    let explicit: Bool
    let artists: [SpotifyArtist]
    let album: SpotifyAlbumSummary?

    enum CodingKeys: String, CodingKey {
        case id, name, uri, explicit, artists, album
        case durationMS = "duration_ms"
    }
}

struct SpotifyPlaylistSummary: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let description: String?
    let images: [SpotifyImage]
}

enum SpotifyPlaylistItemAccess: Sendable, Equatable {
    /// Spotify returned the playlist's items. An empty track list is a genuine empty playlist.
    case available
    /// Development Mode only exposes items for playlists the user owns or collaborates on.
    case restricted
}

struct SpotifyPlaylistDetail: Sendable, Equatable, Identifiable {
    let summary: SpotifyPlaylistSummary
    let tracks: [SpotifyTrack]
    let itemAccess: SpotifyPlaylistItemAccess

    var id: String { summary.id }
}

struct SpotifyDevice: Codable, Sendable, Equatable, Identifiable {
    let id: String?
    let isActive: Bool
    let isPrivateSession: Bool
    let isRestricted: Bool
    let name: String
    let type: String
    let volumePercent: Int?
    let supportsVolume: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case isActive = "is_active"
        case isPrivateSession = "is_private_session"
        case isRestricted = "is_restricted"
        case volumePercent = "volume_percent"
        case supportsVolume = "supports_volume"
    }
}

enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off
    case context
    case track
}

struct PlaybackState: Sendable, Equatable {
    var item: SpotifyTrack?
    var progressMS: Int
    var isPlaying: Bool
    var device: SpotifyDevice?
    var shuffle: Bool
    var repeatMode: RepeatMode
}

enum SearchType: String, Sendable, CaseIterable, Hashable {
    case album, artist, playlist, track
}

struct SearchResults: Sendable, Equatable {
    var tracks: [SpotifyTrack] = []
    var albums: [SpotifyAlbumSummary] = []
    var artists: [SpotifyArtist] = []
    var playlists: [SpotifyPlaylistSummary] = []
}

enum PlayRequest: Sendable, Equatable {
    case uris([String], offset: Int? = nil)
    case context(uri: String, offsetURI: String? = nil)
    case resume
}

struct Page<Element: Sendable>: Sendable {
    let items: [Element]
    let next: URL?
}
