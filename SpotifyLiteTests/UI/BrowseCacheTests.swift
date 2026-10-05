import Foundation
import XCTest
@testable import SpotifyLite

@MainActor
final class BrowseCacheTests: XCTestCase {
    func testCachedValueIsFreshForFifteenMinutes() {
        let storedAt = Date(timeIntervalSince1970: 1_786_533_600)
        let cached = Cached("home", storedAt: storedAt)

        XCTAssertTrue(cached.isFresh(at: storedAt.addingTimeInterval(14 * 60)))
        XCTAssertFalse(cached.isFresh(at: storedAt.addingTimeInterval(15 * 60)))
    }

    func testLibrarySectionFreshnessAndClear() {
        let cache = BrowseCache()
        let loadedAt = Date(timeIntervalSince1970: 1_786_533_600)
        cache.library.loadedAt[.tracks] = loadedAt
        cache.home = Cached(HomeSnapshot(recentTracks: [], playlists: []), storedAt: loadedAt)

        XCTAssertTrue(cache.isLibrarySectionFresh(.tracks, at: loadedAt.addingTimeInterval(60)))
        XCTAssertFalse(cache.isLibrarySectionFresh(.tracks, at: loadedAt.addingTimeInterval(20 * 60)))
        XCTAssertFalse(cache.isLibrarySectionFresh(.albums, at: loadedAt))

        cache.clear()

        XCTAssertNil(cache.home)
        XCTAssertFalse(cache.isLibrarySectionFresh(.tracks, at: loadedAt))
    }
}
