import Foundation
import XCTest
@testable import SpotifyLite

final class SoloistSupervisorTests: XCTestCase {
    func testAudioOutputReportsMonoDefaultInsteadOfFallingBackToSpeakers() {
        let devices = [
            ReceiverAudioOutputDevice(id: 1, name: "Headset", outputChannels: 1, isDefault: true, isBuiltIn: false),
            ReceiverAudioOutputDevice(id: 2, name: "Mac Speakers", outputChannels: 2, isDefault: false, isBuiltIn: true)
        ]

        XCTAssertEqual(ReceiverAudioOutput.statusDescription(from: devices), "Headset")
    }

    func testRedactionRemovesOAuthAndBearerSecrets() {
        let raw = "https://callback/?code=secret-code&state=secret-state Authorization: Bearer abc.def_123"
        let redacted = Redaction.redact(raw)

        XCTAssertFalse(redacted.contains("secret-code"))
        XCTAssertFalse(redacted.contains("secret-state"))
        XCTAssertFalse(redacted.contains("abc.def_123"))
        XCTAssertTrue(redacted.contains("code=<redacted>"))
        XCTAssertTrue(redacted.contains("Bearer <redacted>"))
    }

    func testPairingEndpointIsParsedFromVerboseOutput() {
        let line = "16:54:26.105 I [f:52    ] Started ZeroConf service on port 58240 path /zc\u{1B}[0m"
        let endpoint = SoloistSupervisor.pairingEndpoint(in: line)
        XCTAssertEqual(endpoint?.port, 58_240)
        XCTAssertEqual(endpoint?.path, "/zc")
        XCTAssertNil(SoloistSupervisor.pairingEndpoint(in: "api: websocket server listening on 127.0.0.1:58239"))
    }

    func testBuildExpiryIsNinetyDaysAfterTheBuildDate() throws {
        let line = "soloist 1.3.10.70 build 1794571308 (20261113) (g19412df6ea) (macos/aarch64)"
        let expiry = try XCTUnwrap(SoloistSupervisor.buildExpiry(fromVersionLine: line))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: expiry),
                       DateComponents(year: 2027, month: 2, day: 11))
        XCTAssertNil(SoloistSupervisor.buildExpiry(fromVersionLine: "soloist unknown"))
    }

    func testRedactionRemovesAccountNameFromReceiverLogin() {
        XCTAssertEqual(Redaction.redact("2026-11-13 12:02:32.672: logged in as someone"),
                       "2026-11-13 12:02:32.672: logged in as <redacted>")
    }

    func testStartRequiresAPIKeyBeforeLaunching() async throws {
        let fixture = try makeFixture(paired: true, script: Self.runningScript)
        defer { fixture.cleanUp() }
        let supervisor = SoloistSupervisor(configuration: fixture.configuration, apiKey: { nil })

        do {
            try await supervisor.start()
            XCTFail("Expected an API key to be required")
        } catch let error as SoloistSupervisorError {
            XCTAssertEqual(error, .apiKeyRequired)
        }
    }

    func testStartRequiresPairingBeforeLaunching() async throws {
        let fixture = try makeFixture(paired: false, script: Self.runningScript)
        defer { fixture.cleanUp() }
        let supervisor = SoloistSupervisor(configuration: fixture.configuration, apiKey: { "key" })

        do {
            try await supervisor.start()
            XCTFail("Expected receiver pairing to be required")
        } catch let error as SoloistSupervisorError {
            XCTAssertEqual(error, .authenticationRequired)
        }
    }

    func testStartPassesDeviceKeyAndDirectoriesWithoutLoggingTheKey() async throws {
        let fixture = try makeFixture(paired: true, script: Self.runningScript)
        defer { fixture.cleanUp() }
        let supervisor = SoloistSupervisor(configuration: fixture.configuration, apiKey: { "secret-key-value" })

        try await supervisor.start()
        let didLaunch = await waitForLaunchCount(1, supervisor: supervisor)
        XCTAssertTrue(didLaunch)
        let log = await supervisor.recentLogLines().joined(separator: "\n")
        await supervisor.stop()

        XCTAssertTrue(log.contains("args: --device-name \(fixture.configuration.deviceName) --api-key <key> --data-dir"))
        XCTAssertFalse(log.contains("secret-key-value"))
    }

    func testExpiredBuildIsNotRestarted() async throws {
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "soloist 1.0 build 1 (20260101)"; exit 0; fi
        echo "receiver-launched"
        exit 10
        """
        let fixture = try makeFixture(paired: true, script: script)
        defer { fixture.cleanUp() }
        let supervisor = SoloistSupervisor(configuration: fixture.configuration, apiKey: { "key" })

        try await supervisor.startKeepingAlive()
        let didLaunch = await waitForLaunchCount(1, supervisor: supervisor)
        XCTAssertTrue(didLaunch)
        try await Task.sleep(for: .milliseconds(300))
        let lines = await supervisor.recentLogLines()
        await supervisor.stopKeepingAlive()

        XCTAssertEqual(lines.filter { $0.contains("receiver-launched") }.count, 1)
        XCTAssertTrue(lines.contains { $0.contains("build has expired") })
    }

    func testKeepAliveRelaunchesReceiverAfterUnexpectedExit() async throws {
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "soloist 1.0 build 1 (20260101)"; exit 0; fi
        echo "receiver-launched"
        if [ ! -f "crashed-once" ]; then touch "crashed-once"; exit 3; fi
        trap 'exit 0' TERM INT
        while :; do sleep 1; done
        """
        let fixture = try makeFixture(paired: true, script: script)
        defer { fixture.cleanUp() }
        let supervisor = SoloistSupervisor(configuration: fixture.configuration, apiKey: { "key" })

        try await supervisor.startKeepingAlive()
        let didRelaunch = await waitForLaunchCount(2, supervisor: supervisor)
        await supervisor.stopKeepingAlive()
        XCTAssertTrue(didRelaunch)
    }

    func testDefaultAudioOutputChangeRestartsRunningReceiver() async throws {
        let fixture = try makeFixture(paired: true, script: Self.runningScript)
        defer { fixture.cleanUp() }
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let supervisor = SoloistSupervisor(
            configuration: fixture.configuration,
            apiKey: { "key" },
            defaultAudioOutputChanges: { changes }
        )

        do {
            try await supervisor.start()
            let didLaunchInitially = await waitForLaunchCount(1, supervisor: supervisor)
            XCTAssertTrue(didLaunchInitially)

            continuation.yield(())

            let didRelaunch = await waitForLaunchCount(2, supervisor: supervisor)
            XCTAssertTrue(didRelaunch)
            let log = await supervisor.recentLogLines().joined(separator: "\n")
            XCTAssertTrue(log.contains("macOS default audio output changed"))
            await supervisor.stop()
            continuation.finish()
        } catch {
            continuation.finish()
            await supervisor.stop()
            throw error
        }
    }

    func testLostSessionStopsReceiverAndAsksForPairing() async throws {
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "soloist 1.0 build 1 (20260101)"; exit 0; fi
        echo "receiver-launched"
        echo "waiting for login"
        trap 'exit 0' TERM INT
        while :; do sleep 1; done
        """
        let fixture = try makeFixture(paired: true, script: script)
        defer { fixture.cleanUp() }
        let supervisor = SoloistSupervisor(configuration: fixture.configuration, apiKey: { "key" })
        let events = supervisor.events

        try await supervisor.startKeepingAlive()
        var askedForPairing = false
        for await event in events {
            if event == .stateChanged(.needsAuthentication) { askedForPairing = true; break }
        }
        await supervisor.stopKeepingAlive()
        XCTAssertTrue(askedForPairing)
    }

    private static let runningScript = """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "soloist 1.0 build 1 (20260101)"; exit 0; fi
    echo "receiver-launched"
    echo "args: $1 $2 $3 <key> $5 $6"
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    """

    private struct Fixture {
        let root: URL
        let configuration: SoloistSupervisorConfiguration
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A fake `soloist` executable and, when `paired`, the stored-session marker Soloist writes.
    private func makeFixture(paired: Bool, script: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("soloist")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let configuration = SoloistSupervisorConfiguration(
            userSelectedExecutableURL: executable,
            applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true),
            deviceName: "TestReceiver",
            gracefulStopDelay: .seconds(2),
            keepAliveRestartDelay: .milliseconds(20)
        )
        if paired {
            let user = configuration.dataDirectory.appendingPathComponent("settings/Users/someone-user", isDirectory: true)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        }
        return Fixture(root: root, configuration: configuration)
    }

    private func waitForLaunchCount(_ count: Int, supervisor: SoloistSupervisor) async -> Bool {
        for _ in 0..<100 {
            let lines = await supervisor.recentLogLines()
            if lines.filter({ $0.contains("receiver-launched") }).count >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
