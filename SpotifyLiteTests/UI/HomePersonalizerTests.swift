import Foundation
import XCTest
@testable import SpotifyLite

final class HomePersonalizerTests: XCTestCase {
    func testDayMixIsDeterministicWithinTimeBucketAndRemovesDuplicates() {
        let tracks = [track("a"), track("b"), track("a"), track("c")]
        let date = Date(timeIntervalSince1970: 1_786_533_600)

        let first = HomePersonalizer.dayMix(from: tracks, date: date)
        let second = HomePersonalizer.dayMix(from: tracks, date: date)

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(Set(first.map(\.id)), Set(["a", "b", "c"]))
        XCTAssertEqual(first.count, 3)
    }

    func testPersonalizedSpotifyPlaylistsComeBeforeOrdinaryPlaylists() {
        let playlists = [
            playlist("road", name: "Road Trip"),
            playlist("daylist", name: "Tuesday afternoon daylist"),
            playlist("discover", name: "Discover Weekly"),
            playlist("cooking", name: "Cooking")
        ]

        let result = HomePersonalizer.prioritizedPlaylists(playlists, limit: 4)

        XCTAssertEqual(result.map(\.id), ["daylist", "discover", "road", "cooking"])
    }

    func testRecentAlbumsAndArtistsStayUniqueAndRespectLimits() {
        let sharedAlbum = album("album-1", artist: "Artist One")
        let tracks = [
            track("a", artist: "Artist One", album: sharedAlbum),
            track("b", artist: "Artist One", album: sharedAlbum),
            track("c", artist: "Artist Two", album: album("album-2", artist: "Artist Two"))
        ]

        XCTAssertEqual(HomePersonalizer.uniqueAlbums(from: tracks, limit: 1).map(\.id), ["album-1"])
        XCTAssertEqual(HomePersonalizer.artistNames(from: tracks, limit: 2), ["Artist One", "Artist Two"])
    }

    private func track(
        _ id: String,
        artist: String = "Artist",
        album: SpotifyAlbumSummary? = nil
    ) -> SpotifyTrack {
        SpotifyTrack(
            id: id,
            name: "Track \(id)",
            uri: "spotify:track:\(id)",
            durationMS: 180_000,
            explicit: false,
            artists: [SpotifyArtist(id: "artist-\(artist)", name: artist, uri: nil, images: nil)],
            album: album
        )
    }

    private func album(_ id: String, artist: String) -> SpotifyAlbumSummary {
        SpotifyAlbumSummary(
            id: id,
            name: "Album \(id)",
            uri: "spotify:album:\(id)",
            artists: [SpotifyArtist(id: "artist-\(artist)", name: artist, uri: nil, images: nil)],
            images: [],
            releaseDate: nil
        )
    }

    private func playlist(_ id: String, name: String) -> SpotifyPlaylistSummary {
        SpotifyPlaylistSummary(
            id: id,
            name: name,
            uri: "spotify:playlist:\(id)",
            description: nil,
            images: []
        )
    }
}
