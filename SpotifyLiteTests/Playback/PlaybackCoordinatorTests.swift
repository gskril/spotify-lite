import Foundation
import XCTest
@testable import SpotifyLite

final class PlaybackCoordinatorTests: XCTestCase {
    func testStartupHydratesPausedPlayerFromMostRecentTrackWhenAccountIsIdle() async throws {
        let recent = makeTrack(id: "recent", name: "Last played")
        let api = PlaybackAPISpy(
            deviceResponses: [],
            playbackResponses: [nil],
            recentlyPlayedTracks: [recent]
        )
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: SpotifydManagerSpy(),
            receiverName: "Spotify Lite — Test Mac"
        )

        let hydrated = try await coordinator.hydrateFromAccountHistory()
        _ = try await coordinator.refresh()
        let afterEmptyRefresh = await coordinator.currentPlayback()

        XCTAssertEqual(hydrated?.item, recent)
        XCTAssertEqual(hydrated?.isPlaying, false)
        XCTAssertEqual(hydrated?.progressMS, 0)
        XCTAssertNil(hydrated?.device)
        XCTAssertEqual(afterEmptyRefresh?.item, recent)
        XCTAssertEqual(afterEmptyRefresh?.isPlaying, false)
        let calls = await api.calls
        XCTAssertEqual(calls, ["playback", "recently-played", "playback"])
    }

    func testStartupUsesCurrentPlaybackWithoutLoadingHistory() async throws {
        let current = makeTrack(id: "current", name: "Current song")
        let state = PlaybackState(
            item: current,
            progressMS: 12_000,
            isPlaying: false,
            device: nil,
            shuffle: true,
            repeatMode: .context
        )
        let api = PlaybackAPISpy(
            deviceResponses: [],
            playbackResponses: [state],
            recentlyPlayedTracks: [makeTrack(id: "older", name: "Older song")]
        )
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: SpotifydManagerSpy(),
            receiverName: "Spotify Lite — Test Mac"
        )

        let hydrated = try await coordinator.hydrateFromAccountHistory()

        XCTAssertEqual(hydrated, state)
        let calls = await api.calls
        XCTAssertEqual(calls, ["playback"])
    }

    func testStartupPrefersLocallyRememberedTrackOverLaggingAccountHistory() async throws {
        let local = makeTrack(id: "local", name: "Played before quitting")
        let staleHistory = makeTrack(id: "stale", name: "Older account history")
        let api = PlaybackAPISpy(
            deviceResponses: [],
            playbackResponses: [nil],
            recentlyPlayedTracks: [staleHistory]
        )
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: SpotifydManagerSpy(),
            receiverName: "Spotify Lite — Test Mac"
        )
        let remembered = PlaybackState(
            item: local,
            progressMS: 42_000,
            isPlaying: true,
            device: makeDevice(id: "old-device", active: true),
            shuffle: true,
            repeatMode: .context
        )

        let hydrated = try await coordinator.hydrateFromAccountHistory(
            rememberedPlayback: remembered
        )

        XCTAssertEqual(hydrated?.item, local)
        XCTAssertEqual(hydrated?.progressMS, 0)
        XCTAssertEqual(hydrated?.isPlaying, false)
        XCTAssertNil(hydrated?.device)
        XCTAssertEqual(hydrated?.shuffle, true)
        XCTAssertEqual(hydrated?.repeatMode, .context)
        let calls = await api.calls
        XCTAssertEqual(calls, ["playback"])
    }

    func testPlayStartsRememberedHistoryTrackOnLocalReceiver() async throws {
        let recent = makeTrack(
            id: "recent",
            name: "Last played",
            albumURI: "spotify:album:recent-album"
        )
        let receiver = makeDevice(id: "local-v1", active: false)
        let api = PlaybackAPISpy(
            deviceResponses: [[receiver]],
            playbackResponses: [nil],
            recentlyPlayedTracks: [recent]
        )
        let daemon = SpotifydManagerSpy()
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: daemon,
            receiverName: receiver.name,
            configuration: .init(
                receiverDiscoveryTimeout: .seconds(1),
                initialDiscoveryDelay: .milliseconds(1),
                maximumDiscoveryDelay: .milliseconds(5),
                refreshAfterCommands: false
            )
        )

        _ = try await coordinator.hydrateFromAccountHistory()
        try await coordinator.play()

        let daemonCalls = await daemon.calls
        let apiCalls = await api.calls
        let playback = await coordinator.currentPlayback()
        XCTAssertEqual(daemonCalls, ["start"])
        XCTAssertEqual(apiCalls, [
            "playback",
            "recently-played",
            "devices",
            "play:local-v1:context(spotify:album:recent-album)"
        ])
        XCTAssertEqual(playback?.item, recent)
        XCTAssertEqual(playback?.device, receiver)
        XCTAssertEqual(playback?.isPlaying, true)
    }

    func testPlayResumesExistingStartupSessionOnItsDevice() async throws {
        let current = makeTrack(id: "current", name: "Current song")
        let device = makeDevice(id: "remote-v1", active: true)
        let state = PlaybackState(
            item: current,
            progressMS: 12_000,
            isPlaying: false,
            device: device,
            shuffle: false,
            repeatMode: .off
        )
        let api = PlaybackAPISpy(
            deviceResponses: [[device]],
            playbackResponses: [state]
        )
        let daemon = SpotifydManagerSpy()
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: daemon,
            receiverName: "Spotify Lite — Test Mac",
            configuration: .init(refreshAfterCommands: false)
        )

        _ = try await coordinator.hydrateFromAccountHistory()
        try await coordinator.play()

        let daemonCalls = await daemon.calls
        let apiCalls = await api.calls
        let playback = await coordinator.currentPlayback()
        XCTAssertEqual(daemonCalls, [])
        XCTAssertEqual(apiCalls, [
            "playback",
            "devices",
            "play:remote-v1:resume"
        ])
        XCTAssertEqual(playback?.item, current)
        XCTAssertEqual(playback?.device, device)
        XCTAssertEqual(playback?.isPlaying, true)
    }

    func testLocalPlayUsesExplicitDeviceWithoutTransfer() async throws {
        let inactive = makeDevice(id: "local-v1", active: false)
        let api = PlaybackAPISpy(deviceResponses: [[inactive]])
        let daemon = SpotifydManagerSpy()
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: daemon,
            receiverName: inactive.name,
            configuration: .init(
                receiverDiscoveryTimeout: .seconds(1),
                receiverActivationTimeout: .seconds(1),
                initialDiscoveryDelay: .milliseconds(1),
                maximumDiscoveryDelay: .milliseconds(5),
                refreshAfterCommands: false
            )
        )

        try await coordinator.playLocally(.context(uri: "spotify:album:1"))

        let daemonCalls = await daemon.calls
        let apiCalls = await api.calls
        XCTAssertEqual(daemonCalls, ["start"])
        XCTAssertEqual(apiCalls, [
            "devices",
            "play:local-v1:context(spotify:album:1)"
        ])
    }

    func testKnownTrackUpdatesPlaybackImmediatelyWithoutReadingStaleServerState() async throws {
        let device = makeDevice(id: "local-v1", active: true)
        let oldTrack = makeTrack(id: "old", name: "Old song")
        let selectedTrack = makeTrack(id: "selected", name: "Selected song")
        let api = PlaybackAPISpy(
            deviceResponses: [[device]],
            playbackResponses: [
                PlaybackState(
                    item: oldTrack,
                    progressMS: 30_000,
                    isPlaying: true,
                    device: device,
                    shuffle: true,
                    repeatMode: .context
                ),
                PlaybackState(
                    item: oldTrack,
                    progressMS: 31_000,
                    isPlaying: true,
                    device: device,
                    shuffle: true,
                    repeatMode: .context
                ),
                PlaybackState(
                    item: selectedTrack,
                    progressMS: 500,
                    isPlaying: true,
                    device: device,
                    shuffle: true,
                    repeatMode: .context
                )
            ],
            operationDelay: .milliseconds(80)
        )
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: SpotifydManagerSpy(),
            receiverName: device.name
        )

        _ = try await coordinator.refresh()
        async let command: Void = coordinator.playLocally(
            .uris([selectedTrack.uri]),
            preview: selectedTrack
        )
        try await waitForAPICall(api, prefix: "play:")

        let playbackWhileCommandIsPending = await coordinator.currentPlayback()
        XCTAssertEqual(playbackWhileCommandIsPending?.item, selectedTrack)
        XCTAssertLessThan(playbackWhileCommandIsPending?.progressMS ?? .max, 1_000)
        XCTAssertEqual(playbackWhileCommandIsPending?.isPlaying, true)
        XCTAssertEqual(playbackWhileCommandIsPending?.shuffle, true)
        XCTAssertEqual(playbackWhileCommandIsPending?.repeatMode, .context)

        try await command
        _ = try await coordinator.refresh()
        let playbackAfterStaleRefresh = await coordinator.currentPlayback()
        XCTAssertEqual(playbackAfterStaleRefresh?.item, selectedTrack)

        _ = try await coordinator.refresh()
        let confirmedPlayback = await coordinator.currentPlayback()
        XCTAssertEqual(confirmedPlayback?.item, selectedTrack)
        XCTAssertGreaterThanOrEqual(confirmedPlayback?.progressMS ?? 0, 500)

        let calls = await api.calls
        XCTAssertEqual(calls, [
            "playback",
            "devices",
            "play:local-v1:uris(spotify:track:selected)",
            "playback",
            "playback"
        ])
    }

    func testResumeTransfersWaitsForActiveThenResumesInOrder() async throws {
        let inactive = makeDevice(id: "local-v1", active: false)
        let active = makeDevice(id: "local-v1", active: true)
        let api = PlaybackAPISpy(deviceResponses: [[inactive], [active]])
        let daemon = SpotifydManagerSpy()
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: daemon,
            receiverName: inactive.name,
            configuration: .init(
                receiverDiscoveryTimeout: .seconds(1),
                receiverActivationTimeout: .seconds(1),
                initialDiscoveryDelay: .milliseconds(1),
                maximumDiscoveryDelay: .milliseconds(5),
                refreshAfterCommands: false
            )
        )

        try await coordinator.resume()

        let daemonCalls = await daemon.calls
        let apiCalls = await api.calls
        XCTAssertEqual(daemonCalls, ["start"])
        XCTAssertEqual(apiCalls, [
            "devices",
            "transfer:local-v1:false",
            "devices",
            "play:local-v1:resume"
        ])
    }

    func testReceiverResolutionReplacesStaleDeviceID() async throws {
        let api = PlaybackAPISpy(deviceResponses: [[makeDevice(id: "fresh", active: true)]])
        let daemon = SpotifydManagerSpy()
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: daemon,
            receiverName: "Spotify Lite — Test Mac",
            configuration: .init(refreshAfterCommands: false)
        )

        try await coordinator.pause()

        let calls = await api.calls
        XCTAssertEqual(calls, ["devices", "pause:fresh"])
    }

    func testPauseDoesNotOverwriteOptimisticStateWithAnEventuallyConsistentRefresh() async throws {
        let api = PlaybackAPISpy(deviceResponses: [[makeDevice(id: "fresh", active: true)]])
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: SpotifydManagerSpy(),
            receiverName: "Spotify Lite — Test Mac"
        )

        try await coordinator.pause()

        let calls = await api.calls
        XCTAssertEqual(calls, ["devices", "pause:fresh"])
    }

    func testSystemPlayResumesTheCurrentlyActiveDevice() async throws {
        let api = PlaybackAPISpy(deviceResponses: [[makeDevice(id: "active", active: true)]])
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: SpotifydManagerSpy(),
            receiverName: "Spotify Lite — Test Mac",
            configuration: .init(refreshAfterCommands: false)
        )

        try await coordinator.play()

        let calls = await api.calls
        XCTAssertEqual(calls, ["devices", "play:active:resume"])
    }

    func testConcurrentCommandsAreSerialized() async throws {
        let api = PlaybackAPISpy(
            deviceResponses: [
                [makeDevice(id: "local", active: true)],
                [makeDevice(id: "local", active: true)]
            ],
            operationDelay: .milliseconds(40)
        )
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: SpotifydManagerSpy(),
            receiverName: "Spotify Lite — Test Mac",
            configuration: .init(refreshAfterCommands: false)
        )

        async let first: Void = coordinator.next()
        try await Task.sleep(for: .milliseconds(5))
        async let second: Void = coordinator.previous()
        _ = try await (first, second)

        let calls = await api.calls
        let maximumConcurrentOperations = await api.maximumConcurrentOperations
        XCTAssertEqual(calls, ["devices", "next:local", "devices", "previous:local"])
        XCTAssertEqual(maximumConcurrentOperations, 1)
    }

    func testSeekUsesLatestReceiverDeviceID() async throws {
        let api = PlaybackAPISpy(deviceResponses: [[makeDevice(id: "fresh", active: true)]])
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: SpotifydManagerSpy(),
            receiverName: "Spotify Lite — Test Mac",
            configuration: .init(refreshAfterCommands: false)
        )

        try await coordinator.seek(to: 42_000)

        let calls = await api.calls
        XCTAssertEqual(calls, ["devices", "seek:42000:fresh"])
    }

    func testBackgroundStopsPollingAndRefocusRefreshesImmediately() async throws {
        let api = PlaybackAPISpy(deviceResponses: [])
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: SpotifydManagerSpy(),
            receiverName: "Spotify Lite — Test Mac",
            configuration: .init(
                activeRefreshInterval: .milliseconds(25),
                refreshAfterCommands: false
            )
        )

        await coordinator.setObservationActivity(.active)
        try await waitForPlaybackCalls(api, count: 1)
        await coordinator.setObservationActivity(.hidden)
        let backgroundCount = await api.playbackCallCount()
        try await Task.sleep(for: .milliseconds(60))
        let countWhileBackgrounded = await api.playbackCallCount()
        XCTAssertEqual(countWhileBackgrounded, backgroundCount)

        await coordinator.setObservationActivity(.active)
        try await waitForPlaybackCalls(api, count: backgroundCount + 1)
        await coordinator.setObservationActivity(.hidden)

        let countAfterRefocus = await api.playbackCallCount()
        XCTAssertEqual(countAfterRefocus, backgroundCount + 1)
    }

    func testTransferPlaybackPreservesPlayingStateAndUpdatesActiveDeviceOptimistically() async throws {
        let current = makeDevice(id: "local", active: true)
        let target = SpotifyDevice(
            id: "speaker",
            isActive: false,
            isPrivateSession: false,
            isRestricted: false,
            name: "Kitchen",
            type: "speaker",
            volumePercent: 35,
            supportsVolume: true
        )
        let activatedTarget = SpotifyDevice(
            id: target.id,
            isActive: true,
            isPrivateSession: target.isPrivateSession,
            isRestricted: target.isRestricted,
            name: target.name,
            type: target.type,
            volumePercent: target.volumePercent,
            supportsVolume: target.supportsVolume
        )
        let api = PlaybackAPISpy(
            deviceResponses: [[activatedTarget], [activatedTarget]],
            playbackResponses: [PlaybackState(
                item: nil,
                progressMS: 12_000,
                isPlaying: true,
                device: current,
                shuffle: false,
                repeatMode: .off
            )]
        )
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: SpotifydManagerSpy(),
            receiverName: current.name,
            configuration: .init(refreshAfterCommands: false)
        )

        _ = try await coordinator.refresh()
        try await coordinator.transferPlayback(to: target)
        try await coordinator.next()

        let calls = await api.calls
        let playback = await coordinator.currentPlayback()
        XCTAssertEqual(calls, [
            "playback",
            "transfer:speaker:true",
            "devices",
            "devices",
            "next:speaker"
        ])
        XCTAssertEqual(playback?.device?.id, "speaker")
        XCTAssertEqual(playback?.device?.isActive, true)
        XCTAssertEqual(playback?.isPlaying, true)
    }

    func testTransferPlaybackRejectsRestrictedDevice() async {
        let restricted = SpotifyDevice(
            id: "restricted",
            isActive: false,
            isPrivateSession: false,
            isRestricted: true,
            name: "Unavailable speaker",
            type: "speaker",
            volumePercent: nil,
            supportsVolume: false
        )
        let coordinator = PlaybackCoordinator(
            api: PlaybackAPISpy(deviceResponses: []),
            spotifyd: SpotifydManagerSpy(),
            receiverName: "Spotify Lite — Test Mac"
        )

        do {
            try await coordinator.transferPlayback(to: restricted)
            XCTFail("Expected a restricted-device error")
        } catch {
            XCTAssertEqual(
                error as? PlaybackCoordinatorError,
                .deviceRestricted(name: restricted.name)
            )
        }
    }

    func testTransferPlaybackFallsBackToTargetedResumeWhenSpotifyDoesNotActivateDevice() async throws {
        let current = makeDevice(id: "local", active: true)
        let inactiveTarget = SpotifyDevice(
            id: "desktop",
            isActive: false,
            isPrivateSession: false,
            isRestricted: false,
            name: "Desktop Spotify",
            type: "computer",
            volumePercent: 40,
            supportsVolume: true
        )
        let activeTarget = SpotifyDevice(
            id: inactiveTarget.id,
            isActive: true,
            isPrivateSession: false,
            isRestricted: false,
            name: inactiveTarget.name,
            type: inactiveTarget.type,
            volumePercent: inactiveTarget.volumePercent,
            supportsVolume: true
        )
        let api = PlaybackAPISpy(
            deviceResponses: [[inactiveTarget], [activeTarget]],
            playbackResponses: [PlaybackState(
                item: nil,
                progressMS: 20_000,
                isPlaying: true,
                device: current,
                shuffle: false,
                repeatMode: .off
            )]
        )
        let coordinator = PlaybackCoordinator(
            api: api,
            spotifyd: SpotifydManagerSpy(),
            receiverName: current.name,
            configuration: .init(
                receiverActivationTimeout: .milliseconds(10),
                refreshAfterCommands: false
            )
        )

        _ = try await coordinator.refresh()
        try await coordinator.transferPlayback(to: inactiveTarget)

        let calls = await api.calls
        let playback = await coordinator.currentPlayback()
        XCTAssertEqual(calls, [
            "playback",
            "transfer:desktop:true",
            "devices",
            "play:desktop:resume",
            "devices"
        ])
        XCTAssertEqual(playback?.device?.id, "desktop")
        XCTAssertEqual(playback?.device?.isActive, true)
    }

    private func makeDevice(id: String, active: Bool) -> SpotifyDevice {
        SpotifyDevice(
            id: id,
            isActive: active,
            isPrivateSession: false,
            isRestricted: false,
            name: "Spotify Lite — Test Mac",
            type: "computer",
            volumePercent: 50,
            supportsVolume: true
        )
    }

    private func makeTrack(id: String, name: String, albumURI: String? = nil) -> SpotifyTrack {
        SpotifyTrack(
            id: id,
            name: name,
            uri: "spotify:track:\(id)",
            durationMS: 180_000,
            explicit: false,
            artists: [SpotifyArtist(id: "artist", name: "Artist", uri: nil, images: nil)],
            album: albumURI.map { uri in
                SpotifyAlbumSummary(
                    id: "album",
                    name: "Album",
                    uri: uri,
                    artists: [],
                    images: [],
                    releaseDate: nil
                )
            }
        )
    }

    private func waitForPlaybackCalls(_ api: PlaybackAPISpy, count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await api.playbackCallCount() < count {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for playback refresh")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForAPICall(_ api: PlaybackAPISpy, prefix: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !(await api.calls).contains(where: { $0.hasPrefix(prefix) }) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for API call beginning with \(prefix)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor SpotifydManagerSpy: SpotifydManaging {
    nonisolated let events = AsyncStream<SpotifydEvent> { _ in }
    private(set) var calls: [String] = []

    func inspectInstallation() async -> SpotifydInstallation {
        .init(executableURL: URL(fileURLWithPath: "/fixture/spotifyd"), version: "fixture")
    }

    func authenticate() async throws { calls.append("authenticate") }
    func start() async throws { calls.append("start") }
    func stop() async { calls.append("stop") }
}

private actor PlaybackAPISpy: SpotifyAPIProviding {
    private var deviceResponses: [[SpotifyDevice]]
    private var playbackResponses: [PlaybackState?]
    private let operationDelay: Duration
    private let recentlyPlayedTracks: [SpotifyTrack]
    private(set) var calls: [String] = []
    private(set) var activeOperations = 0
    private(set) var maximumConcurrentOperations = 0

    init(
        deviceResponses: [[SpotifyDevice]],
        playbackResponses: [PlaybackState?] = [],
        recentlyPlayedTracks: [SpotifyTrack] = [],
        operationDelay: Duration = .zero
    ) {
        self.deviceResponses = deviceResponses
        self.playbackResponses = playbackResponses
        self.recentlyPlayedTracks = recentlyPlayedTracks
        self.operationDelay = operationDelay
    }

    func currentUser() async throws -> SpotifyUser { throw PlaceholderError.notConfigured }
    func recentlyPlayed() async throws -> [SpotifyTrack] {
        calls.append("recently-played")
        return recentlyPlayedTracks
    }
    func savedTracks() async throws -> [SpotifyTrack] { [] }
    func savedAlbums() async throws -> [SpotifyAlbumSummary] { [] }
    func currentUserPlaylists() async throws -> [SpotifyPlaylistSummary] { [] }
    func playbackState() async throws -> PlaybackState? {
        calls.append("playback")
        guard !playbackResponses.isEmpty else { return nil }
        return playbackResponses.removeFirst()
    }
    func playbackQueue() async throws -> PlaybackQueue { .init(currentlyPlaying: nil, upcoming: []) }

    func playbackCallCount() -> Int {
        calls.count(where: { $0 == "playback" })
    }

    func devices() async throws -> [SpotifyDevice] {
        calls.append("devices")
        guard !deviceResponses.isEmpty else { return [] }
        return deviceResponses.removeFirst()
    }

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        calls.append("transfer:\(deviceID):\(play)")
    }

    func play(_ request: PlayRequest, on deviceID: String?) async throws {
        await recordOperation("play:\(deviceID ?? "nil"):\(describe(request))")
    }

    func pause(on deviceID: String?) async throws { await recordOperation("pause:\(deviceID ?? "nil")") }
    func next(on deviceID: String?) async throws { await recordOperation("next:\(deviceID ?? "nil")") }
    func previous(on deviceID: String?) async throws { await recordOperation("previous:\(deviceID ?? "nil")") }
    func seek(to milliseconds: Int, on deviceID: String?) async throws { await recordOperation("seek:\(milliseconds):\(deviceID ?? "nil")") }
    func setVolume(_ percent: Int, on deviceID: String?) async throws { await recordOperation("volume:\(percent):\(deviceID ?? "nil")") }
    func setShuffle(_ enabled: Bool, on deviceID: String?) async throws { await recordOperation("shuffle:\(enabled):\(deviceID ?? "nil")") }
    func setRepeat(_ mode: RepeatMode, on deviceID: String?) async throws { await recordOperation("repeat:\(mode.rawValue):\(deviceID ?? "nil")") }
    func addToQueue(uri: String, on deviceID: String?) async throws { await recordOperation("queue:\(uri):\(deviceID ?? "nil")") }
    func search(_ query: String, types: Set<SearchType>) async throws -> SearchResults { .init() }
    func setSaved(trackID: String, saved: Bool) async throws {}

    private func recordOperation(_ value: String) async {
        calls.append(value)
        activeOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)
        if operationDelay != .zero { try? await Task.sleep(for: operationDelay) }
        activeOperations -= 1
    }

    private func describe(_ request: PlayRequest) -> String {
        switch request {
        case .resume: "resume"
        case .uris(let uris, _): "uris(\(uris.joined(separator: ",")))"
        case .context(let uri, _): "context(\(uri))"
        }
    }
}

private extension PlaybackCoordinatorConfiguration {
    init(
        receiverDiscoveryTimeout: Duration = .seconds(20),
        receiverActivationTimeout: Duration = .seconds(8),
        initialDiscoveryDelay: Duration = .milliseconds(250),
        maximumDiscoveryDelay: Duration = .seconds(2),
        seekDebounceDelay: Duration = .milliseconds(180),
        volumeDebounceDelay: Duration = .milliseconds(180),
        activeRefreshInterval: Duration = .seconds(3),
        refreshAfterCommands: Bool = true
    ) {
        self.init()
        self.receiverDiscoveryTimeout = receiverDiscoveryTimeout
        self.receiverActivationTimeout = receiverActivationTimeout
        self.initialDiscoveryDelay = initialDiscoveryDelay
        self.maximumDiscoveryDelay = maximumDiscoveryDelay
        self.seekDebounceDelay = seekDebounceDelay
        self.volumeDebounceDelay = volumeDebounceDelay
        self.activeRefreshInterval = activeRefreshInterval
        self.refreshAfterCommands = refreshAfterCommands
    }
}
