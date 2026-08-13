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

    func testSpotifyGeneratedAndJumpBackInRowsAreStrictlySeparated() {
        let playlists = [
            playlist("road", name: "Road Trip", ownerID: "listener"),
            playlist("daylist", name: "Tuesday afternoon daylist", ownerID: "spotify"),
            playlist("daily", name: "Daily Mix 2", ownerID: "spotify"),
            playlist("discover", name: "Discover Weekly", ownerID: "spotify"),
            playlist(
                "daylist-description",
                name: "new wave 80s alternative wednesday night",
                ownerID: "spotify",
                description: "Your daylist changes throughout the day"
            ),
            playlist("copy", name: "Discover Weekly Saved 12", ownerID: "listener"),
            playlist("chill", name: "Chill Mix", ownerID: "spotify"),
            playlist("cooking", name: "Cooking", ownerID: "listener")
        ]

        let madeForYou = HomePersonalizer.spotifyGeneratedPlaylists(playlists, limit: 12)
        let jumpBackIn = HomePersonalizer.jumpBackInPlaylists(playlists, limit: 12)

        XCTAssertEqual(madeForYou.map(\.id), ["daylist", "daily", "discover", "daylist-description", "chill"])
        XCTAssertEqual(jumpBackIn.map(\.id), ["road", "copy", "cooking"])
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

    private func playlist(
        _ id: String,
        name: String,
        ownerID: String,
        description: String? = nil
    ) -> SpotifyPlaylistSummary {
        SpotifyPlaylistSummary(
            id: id,
            name: name,
            uri: "spotify:playlist:\(id)",
            description: description,
            images: [],
            owner: SpotifyPlaylistOwner(id: ownerID, displayName: ownerID.capitalized)
        )
    }
}
