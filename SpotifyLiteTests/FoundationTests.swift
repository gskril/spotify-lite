import XCTest
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
}
