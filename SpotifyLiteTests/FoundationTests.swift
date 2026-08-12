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
}
