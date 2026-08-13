import XCTest
import MediaPlayer
@testable import SpotifyLite

final class FoundationTests: XCTestCase {
    func testAppDestinationsRemainStable() {
        XCTAssertEqual(AppDestination.allCases, [.home, .library, .search, .settings])
    }

    func testAbsentDaemonIsNotInstalled() {
        let installation = SpotifydInstallation(executableURL: nil, version: nil)
        XCTAssertFalse(installation.isInstalled)
    }

    func testArtworkSelectsSmallestImageThatFitsRenderedSize() {
        let edges: [Int] = [64, 300, 640]
        let images = edges.map { edge in
            SpotifyImage(
                url: URL(string: "https://example.com/\(edge).jpg")!,
                width: edge,
                height: edge
            )
        }

        XCTAssertEqual(
            images.artworkURL(forPointSize: 132, displayScale: 2)?.lastPathComponent,
            "300.jpg"
        )
        XCTAssertEqual(
            images.artworkURL(forPointSize: 154, displayScale: 2)?.lastPathComponent,
            "300.jpg"
        )
        XCTAssertEqual(
            images.artworkURL(forPointSize: 400, displayScale: 2)?.lastPathComponent,
            "640.jpg"
        )
    }

    func testArtworkFallsBackWhenSpotifyOmitsDimensions() {
        let image = SpotifyImage(
            url: URL(string: "https://example.com/unknown.jpg")!,
            width: nil,
            height: nil
        )

        XCTAssertEqual([image].artworkURL(forPointSize: 150), image.url)
    }

    func testPlaybackMemoryIsScopedToTheAccountAndRestoresPositionPaused() {
        let suiteName = "PlaybackMemoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlaybackMemoryStore(defaults: defaults, key: "fixture")
        let track = SpotifyTrack(
            id: "remembered",
            name: "Remembered song",
            uri: "spotify:track:remembered",
            durationMS: 180_000,
            explicit: false,
            artists: [],
            album: nil
        )
        let playback = PlaybackState(
            item: track,
            progressMS: 27_000,
            isPlaying: true,
            device: nil,
            shuffle: true,
            repeatMode: .track,
            contextURI: "spotify:playlist:remembered"
        )

        store.save(playback, for: "account-a")

        let restored = store.load(for: "account-a")
        XCTAssertEqual(restored?.item, track)
        XCTAssertEqual(restored?.progressMS, 27_000)
        XCTAssertEqual(restored?.isPlaying, false)
        XCTAssertNil(restored?.device)
        XCTAssertEqual(restored?.shuffle, true)
        XCTAssertEqual(restored?.repeatMode, .track)
        XCTAssertEqual(restored?.contextURI, "spotify:playlist:remembered")
        XCTAssertNil(store.load(for: "account-b"))

        store.clear()
        XCTAssertNil(store.load(for: "account-a"))
    }

    @MainActor
    func testSystemNowPlayingInfoContainsTrackState() {
        let track = SpotifyTrack(
            id: "track",
            name: "A Song",
            uri: "spotify:track:track",
            durationMS: 240_000,
            explicit: false,
            artists: [SpotifyArtist(id: "artist", name: "An Artist", uri: nil, images: nil)],
            album: SpotifyAlbumSummary(
                id: "album",
                name: "An Album",
                uri: "spotify:album:album",
                artists: [],
                images: [],
                releaseDate: nil
            )
        )
        let info = SystemMediaController.nowPlayingInfo(for: PlaybackState(
            item: track,
            progressMS: 15_000,
            isPlaying: true,
            device: nil,
            shuffle: false,
            repeatMode: .off
        ))

        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "A Song")
        XCTAssertEqual(info?[MPMediaItemPropertyArtist] as? String, "An Artist")
        XCTAssertEqual(info?[MPMediaItemPropertyAlbumTitle] as? String, "An Album")
        XCTAssertEqual(info?[MPMediaItemPropertyPlaybackDuration] as? Double, 240)
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 15)
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
    }

    @MainActor
    func testSelectedTrackPreviewIsImmediatelyReadyForTheBottomPlayer() {
        let previousDevice = SpotifyDevice(
            id: "device",
            isActive: true,
            isPrivateSession: false,
            isRestricted: false,
            name: "This Mac",
            type: "computer",
            volumePercent: 42,
            supportsVolume: true
        )
        let previous = PlaybackState(
            item: nil,
            progressMS: 90_000,
            isPlaying: false,
            device: previousDevice,
            shuffle: true,
            repeatMode: .context
        )
        let selected = SpotifyTrack(
            id: "selected",
            name: "Selected",
            uri: "spotify:track:selected",
            durationMS: 180_000,
            explicit: false,
            artists: [],
            album: nil
        )

        let preview = AppEnvironment.previewPlayback(for: selected, preserving: previous)

        XCTAssertEqual(preview.item, selected)
        XCTAssertEqual(preview.progressMS, 0)
        XCTAssertTrue(preview.isPlaying)
        XCTAssertEqual(preview.device, previousDevice)
        XCTAssertTrue(preview.shuffle)
        XCTAssertEqual(preview.repeatMode, .context)
    }
}
