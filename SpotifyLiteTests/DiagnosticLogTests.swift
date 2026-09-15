import Foundation
import XCTest
@testable import SpotifyLite

final class DiagnosticLogTests: XCTestCase {
    func testAppendAcrossLaunchesAndRedaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        log.record("test", ["message": "Bearer secret-value access_token=private-value"])
        log.flush()
        let second = DiagnosticLog(directory: directory)
        second.record("next")
        second.flush()
        let file = directory.appendingPathComponent("app.jsonl")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertFalse(text.contains("secret-value"))
        XCTAssertFalse(text.contains("private-value"))
        for line in text.split(separator: "\n") {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testRotationBoundsRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory, maximumBytes: 512, archives: 2)
        for index in 0..<20 { log.record("test", ["index": String(index)]) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(files), Set(["app.jsonl", "app.jsonl.1", "app.jsonl.2"]))
        let current = try String(contentsOf: directory.appendingPathComponent("app.jsonl"), encoding: .utf8)
        XCTAssertTrue(current.contains("19"))
    }
}
