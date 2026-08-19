import Foundation

enum PlaybackCoordinatorError: LocalizedError, Sendable, Equatable {
    case receiverNotFound(name: String)
    case receiverHasNoDeviceID(name: String)
    case receiverDidNotBecomeActive(name: String)
    case deviceRestricted(name: String)
    case activeDeviceNotFound
    case deviceDidNotBecomeActive(name: String)
    case deviceCommandRejected(name: String)

    var errorDescription: String? {
        switch self {
        case .receiverNotFound(let name):
            "Spotify Connect did not discover \(name). Check spotifyd authentication and network access."
        case .receiverHasNoDeviceID(let name):
            "Spotify reported \(name), but did not provide a controllable device ID."
        case .receiverDidNotBecomeActive(let name):
            "Spotify did not finish transferring playback to \(name)."
        case .deviceRestricted(let name):
            "Spotify does not allow remote control of \(name)."
        case .activeDeviceNotFound:
            "Spotify did not report an available playback device. Open Spotify on a device and try again."
        case .deviceDidNotBecomeActive(let name):
            "Spotify did not finish switching playback to \(name). Refresh the device list and try again."
        case .deviceCommandRejected(let name):
            "Spotify could not start playback on \(name). Open Spotify on that device, play something once, then refresh and try again."
        }
    }
}

enum PlaybackCoordinatorEvent: Sendable, Equatable {
    case stateChanged(PlaybackState?)
    case commandFailed(String)
    case receiverChanged(SpotifyDevice?)
}

struct PlaybackCoordinatorConfiguration: Sendable {
    var receiverDiscoveryTimeout: Duration = .seconds(20)
    var receiverActivationTimeout: Duration = .seconds(8)
    var initialDiscoveryDelay: Duration = .milliseconds(250)
    var maximumDiscoveryDelay: Duration = .seconds(2)
    var seekDebounceDelay: Duration = .milliseconds(180)
    var volumeDebounceDelay: Duration = .milliseconds(180)
    var activeRefreshInterval: Duration = .seconds(5)
    var receiverRediscoveryTimeoutBeforeRestart: Duration = .seconds(3)
    var refreshAfterCommands: Bool = true
}

private final class PlaybackEventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<PlaybackCoordinatorEvent>.Continuation] = [:]

    func stream() -> AsyncStream<PlaybackCoordinatorEvent> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(128)) { continuation in
            lock.withLock { continuations[identifier] = continuation }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.continuations.removeValue(forKey: identifier) }
            }
        }
    }

    func send(_ event: PlaybackCoordinatorEvent) {
        let listeners = lock.withLock { Array(continuations.values) }
        for listener in listeners { listener.yield(event) }
    }
}

private actor PlaybackCommandGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

actor PlaybackCoordinator {
    private let api: any SpotifyAPIProviding
    private let spotifyd: any SpotifydManaging
    private let receiverName: String
    private let configuration: PlaybackCoordinatorConfiguration
    private let eventBus = PlaybackEventBus()
    private let commandGate = PlaybackCommandGate()
    private let clock = ContinuousClock()

    private var serverPlayback: PlaybackState?
    private var serverPlaybackTimestamp: ContinuousClock.Instant?
    private var receiver: SpotifyDevice?
    private var observationActivity: PlaybackObservationActivity = .hidden
    private var reconciliationTask: Task<Void, Never>?
    private var receiverRecoveryTask: Task<Void, Never>?
    private var receiverRecoveryIdentifier: UUID?
    private var pendingSeekTask: Task<Void, Never>?
    private var pendingVolumeTask: Task<Void, Never>?
    private var pendingSelectedTrackURI: String?
    private var pendingSelectedTrackDeadline: ContinuousClock.Instant?

    nonisolated var events: AsyncStream<PlaybackCoordinatorEvent> { eventBus.stream() }

    init(
        api: any SpotifyAPIProviding,
        spotifyd: any SpotifydManaging,
        receiverName: String,
        configuration: PlaybackCoordinatorConfiguration = .init()
    ) {
        self.api = api
        self.spotifyd = spotifyd
        self.receiverName = receiverName
        self.configuration = configuration
    }

    deinit {
        reconciliationTask?.cancel()
        receiverRecoveryTask?.cancel()
        pendingSeekTask?.cancel()
        pendingVolumeTask?.cancel()
    }

    func currentPlayback() -> PlaybackState? {
        guard var playback = serverPlayback,
              playback.isPlaying,
              let timestamp = serverPlaybackTimestamp else {
            return serverPlayback
        }
        let elapsed = timestamp.duration(to: clock.now)
        let components = elapsed.components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        let upperBound = Int64(playback.item?.durationMS ?? Int.max)
        let interpolated = min(Int64(playback.progressMS) + milliseconds, upperBound)
        playback.progressMS = Int(max(0, min(interpolated, Int64(Int.max))))
        return playback
    }

    /// Hydrates the player when an authenticated session becomes ready. Spotify returns no
    /// playback object when every device is idle, so prefer the app's last known track before
    /// consulting account history, which Spotify may update after a delay.
    @discardableResult
    func hydrateFromAccountHistory(
        rememberedPlayback: PlaybackState? = nil
    ) async throws -> PlaybackState? {
        if let state = try await api.playbackState() {
            setPlayback(state)
            if let device = state.device, device.name == receiverName {
                updateReceiver(device)
            }
            return state
        }

        if serverPlayback?.item != nil { return currentPlayback() }
        if var remembered = rememberedPlayback, remembered.item != nil {
            remembered.isPlaying = false
            remembered.device = nil
            setPlayback(remembered)
            return remembered
        }
        guard let track = try await api.mostRecentlyPlayed() else { return nil }
        let remembered = PlaybackState(
            item: track,
            progressMS: 0,
            isPlaying: false,
            device: nil,
            shuffle: false,
            repeatMode: .off
        )
        setPlayback(remembered)
        return remembered
    }

    @discardableResult
    func refresh() async throws -> PlaybackState? {
        let state = try await api.playbackState()
        if let pendingSelectedTrackURI {
            if state?.item?.uri == pendingSelectedTrackURI, state?.isPlaying == true {
                self.pendingSelectedTrackURI = nil
                pendingSelectedTrackDeadline = nil
            } else if let pendingSelectedTrackDeadline, clock.now < pendingSelectedTrackDeadline {
                return currentPlayback()
            } else {
                self.pendingSelectedTrackURI = nil
                pendingSelectedTrackDeadline = nil
            }
        }
        // spotifyd briefly disappears from Spotify Connect while its session reconnects. Keep
        // the last authoritative playing state during recovery instead of converting one 204
        // response into a paused, device-less player.
        if state == nil,
           receiverRecoveryTask != nil,
           serverPlayback?.isPlaying == true,
           let heldPlayback = currentPlayback() {
            setPlayback(heldPlayback)
            return heldPlayback
        }
        if state == nil, var remembered = serverPlayback, remembered.item != nil {
            remembered.isPlaying = false
            if let device = remembered.device {
                remembered.device = Self.copy(device, isActive: false)
            }
            setPlayback(remembered)
            return remembered
        }
        setPlayback(state)
        if let device = state?.device, device.name == receiverName {
            updateReceiver(device)
        }
        return state
    }

    /// spotifyd can keep running after its Spotify transport closes, or exit without preserving
    /// its playing context. Refresh the receiver session and retain the exact track and position
    /// that were authoritative immediately before the interruption.
    func receiverConnectionInterrupted(restartReceiver: Bool = false) {
        guard receiverRecoveryTask == nil,
              let snapshot = currentPlayback(),
              snapshot.device?.name == receiverName,
              snapshot.item != nil else {
            return
        }

        let identifier = UUID()
        receiverRecoveryIdentifier = identifier
        receiverRecoveryTask = Task { [weak self] in
            await self?.runReceiverRecovery(
                snapshot: snapshot,
                identifier: identifier,
                restartReceiver: restartReceiver
            )
        }
    }

    func setObservationActivity(_ activity: PlaybackObservationActivity) {
        guard observationActivity != activity || reconciliationTask == nil else { return }
        observationActivity = activity
        reconciliationTask?.cancel()
        reconciliationTask = nil
        guard activity != .hidden else { return }
        reconciliationTask = Task { [weak self] in
            await self?.runReconciliationLoop()
        }
    }

    func setVisible(_ visible: Bool) {
        setObservationActivity(visible ? .active : .hidden)
    }

    func availableDevices() async throws -> [SpotifyDevice] {
        try await api.devices()
    }

    func transferPlayback(to device: SpotifyDevice) async throws {
        cancelReceiverRecovery()
        guard !device.isRestricted else {
            throw PlaybackCoordinatorError.deviceRestricted(name: device.name)
        }
        guard let deviceID = device.id else {
            throw PlaybackCoordinatorError.receiverHasNoDeviceID(name: device.name)
        }

        try await serialized {
            let shouldPlay = self.serverPlayback?.isPlaying == true
            let activeDevice = Self.copy(device, isActive: true)
            var confirmedDevice = activeDevice
            try await self.optimistically(updating: { playback in
                playback?.device = activeDevice
            }) {
                try await self.api.transferPlayback(to: deviceID, play: shouldPlay)
                do {
                    confirmedDevice = try await self.waitUntilDeviceIsActive(
                        expectedID: deviceID,
                        name: device.name,
                        timeout: shouldPlay
                            ? min(self.configuration.receiverActivationTimeout, .seconds(2))
                            : self.configuration.receiverActivationTimeout
                    )
                } catch {
                    guard shouldPlay,
                          let coordinatorError = error as? PlaybackCoordinatorError,
                          case .deviceDidNotBecomeActive = coordinatorError else {
                        throw error
                    }

                    // Some Spotify clients acknowledge Transfer Playback without becoming active.
                    // A targeted resume is the documented single-device playback route and makes
                    // the selected Connect device authoritative without restarting the context.
                    do {
                        try await self.api.play(.resume, on: deviceID)
                    } catch let apiError as SpotifyAPIError {
                        switch apiError {
                        case .forbidden, .http(status: 403, reason: _, message: _):
                            throw PlaybackCoordinatorError.deviceCommandRejected(name: device.name)
                        default:
                            throw apiError
                        }
                    }
                    confirmedDevice = try await self.waitUntilDeviceIsActive(
                        expectedID: deviceID,
                        name: device.name
                    )
                }
            }
            self.serverPlayback?.device = confirmedDevice
            self.eventBus.send(.stateChanged(self.serverPlayback))
            if device.name == self.receiverName {
                self.updateReceiver(confirmedDevice)
            }
        }
    }

    func playLocally(_ request: PlayRequest, preview: SpotifyTrack? = nil) async throws {
        cancelReceiverRecovery()
        let playbackRequest = Self.contextualized(request, preview: preview)
        let originalPlayback = serverPlayback
        let originalPlaybackTimestamp = serverPlaybackTimestamp
        let previousPendingTrackURI = pendingSelectedTrackURI
        let previousPendingTrackDeadline = pendingSelectedTrackDeadline
        if let preview {
            installPendingPreview(preview, request: playbackRequest)
        }
        do {
            try await serialized {
                try await self.optimistically(updating: { playback in
                    if let preview {
                        playback = PlaybackState(
                            item: preview,
                            progressMS: 0,
                            isPlaying: true,
                            device: playback?.device,
                            shuffle: playback?.shuffle ?? false,
                            repeatMode: playback?.repeatMode ?? .off
                        )
                    } else {
                        playback?.isPlaying = true
                    }
                }) {
                    let device = try await self.prepareLocalReceiver()
                    guard let deviceID = device.id else {
                        throw PlaybackCoordinatorError.receiverHasNoDeviceID(name: self.receiverName)
                    }
                    self.updateReceiver(device)
                    self.serverPlayback?.device = device
                    self.serverPlaybackTimestamp = self.clock.now
                    self.eventBus.send(.stateChanged(self.serverPlayback))
                    try await self.api.play(playbackRequest, on: deviceID)
                }
                // The Web API playback state is eventually consistent after starting a new item.
                // Keep a known clicked track visible until the regular reconciliation poll confirms it,
                // rather than immediately replacing it with the previous server response.
                if preview == nil {
                    try await self.refreshAfterCommandIfNeeded()
                }
            }
        } catch {
            pendingSelectedTrackURI = previousPendingTrackURI
            pendingSelectedTrackDeadline = previousPendingTrackDeadline
            serverPlayback = originalPlayback
            serverPlaybackTimestamp = originalPlaybackTimestamp
            eventBus.send(.stateChanged(originalPlayback))
            throw error
        }
    }

    private func installPendingPreview(_ preview: SpotifyTrack, request: PlayRequest) {
        pendingSelectedTrackURI = preview.uri
        pendingSelectedTrackDeadline = clock.now.advanced(by: .seconds(12))
        serverPlayback = PlaybackState(
            item: preview,
            progressMS: 0,
            isPlaying: true,
            device: serverPlayback?.device,
            shuffle: serverPlayback?.shuffle ?? false,
            repeatMode: serverPlayback?.repeatMode ?? .off,
            contextURI: Self.contextURI(from: request) ?? serverPlayback?.contextURI
        )
        serverPlaybackTimestamp = clock.now
        eventBus.send(.stateChanged(serverPlayback))
    }

    private static func contextualized(
        _ request: PlayRequest,
        preview: SpotifyTrack?
    ) -> PlayRequest {
        guard case .uris(let uris, _, let positionMS) = request,
              uris.count == 1,
              let preview,
              uris[0] == preview.uri,
              let albumURI = preview.album?.uri else {
            return request
        }
        // spotifyd needs a real context to establish its queue. A one-item URI list can
        // be acknowledged by the Web API but then rejected by the receiver.
        return .context(uri: albumURI, offsetURI: preview.uri, positionMS: positionMS)
    }

    private static func contextURI(from request: PlayRequest) -> String? {
        guard case .context(let uri, _, _) = request else { return nil }
        return uri
    }

    func resume() async throws {
        cancelReceiverRecovery()
        try await serialized {
            var device = try await self.prepareLocalReceiver()
            guard let deviceID = device.id else {
                throw PlaybackCoordinatorError.receiverHasNoDeviceID(name: self.receiverName)
            }
            if !device.isActive {
                try await self.api.transferPlayback(to: deviceID, play: false)
                device = try await self.waitUntilReceiverIsActive(expectedID: deviceID)
            }
            self.updateReceiver(device)
            try await self.optimistically(updating: { $0?.isPlaying = true }) {
                try await self.api.play(.resume, on: deviceID)
            }
            try await self.refreshAfterCommandIfNeeded()
        }
    }

    func pause() async throws {
        try await withReceiverCommand(optimistic: { $0?.isPlaying = false }, refreshAfter: false) { deviceID in
            try await self.api.pause(on: deviceID)
        }
    }

    func play() async throws {
        cancelReceiverRecovery()
        let fallback = currentPlayback()
        try await serialized {
            if fallback?.item == nil || (
                fallback?.device?.isActive == true && fallback?.device?.name != self.receiverName
            ) {
                let device: SpotifyDevice
                do {
                    device = try await self.resolveCommandDevice()
                } catch let error as PlaybackCoordinatorError {
                    guard case .activeDeviceNotFound = error,
                          let fallback,
                          fallback.item != nil else {
                        throw error
                    }
                    let receiver = try await self.prepareLocalReceiver()
                    try await self.restore(fallback, on: receiver)
                    return
                }
                if let fallback,
                   fallback.item != nil,
                   fallback.device?.name != self.receiverName,
                   device.name == self.receiverName {
                    try await self.restore(fallback, on: device)
                    return
                }
                guard let deviceID = device.id else {
                    throw PlaybackCoordinatorError.receiverHasNoDeviceID(name: device.name)
                }
                try await self.confirmingPlay(for: fallback?.item?.uri) {
                    try await self.optimistically(updating: { $0?.isPlaying = true }) {
                        try await self.api.play(.resume, on: deviceID)
                    }
                }
                return
            }

            // Re-read the account before resuming. A long-idle Connect session may have either
            // moved to another device or expired completely while the UI still has a useful
            // paused snapshot.
            if let live = try await self.api.playbackState() {
                self.setPlayback(live)
                let device = try await self.commandDevice(for: live)
                guard let deviceID = device.id else {
                    throw PlaybackCoordinatorError.receiverHasNoDeviceID(name: device.name)
                }
                try await self.confirmingPlay(for: live.item?.uri) {
                    try await self.optimistically(updating: { playback in
                        playback?.isPlaying = true
                        playback?.device = Self.copy(device, isActive: true)
                    }) {
                        try await self.api.play(.resume, on: deviceID)
                    }
                }
                return
            }

            // Spotify returns 204 after an idle session ages out. Recreate the last confirmed
            // context atomically at its saved position instead of issuing a context-less resume.
            if let fallback, fallback.item != nil {
                let device = try await self.prepareLocalReceiver()
                try await self.restore(fallback, on: device)
                return
            }

        }
    }

    func next() async throws {
        try await withReceiverCommand { deviceID in try await self.api.next(on: deviceID) }
    }

    func previous() async throws {
        try await withReceiverCommand { deviceID in try await self.api.previous(on: deviceID) }
    }

    func setShuffle(_ enabled: Bool) async throws {
        try await withReceiverCommand(optimistic: { $0?.shuffle = enabled }, refreshAfter: false) { deviceID in
            try await self.api.setShuffle(enabled, on: deviceID)
        }
    }

    func setRepeat(_ mode: RepeatMode) async throws {
        try await withReceiverCommand(optimistic: { $0?.repeatMode = mode }, refreshAfter: false) { deviceID in
            try await self.api.setRepeat(mode, on: deviceID)
        }
    }

    func addToQueue(uri: String) async throws {
        try await withReceiverCommand(refreshAfter: false) { deviceID in
            try await self.api.addToQueue(uri: uri, on: deviceID)
        }
    }

    func seek(to milliseconds: Int, final: Bool = true) async throws {
        let value = max(0, milliseconds)
        pendingSeekTask?.cancel()
        pendingSeekTask = nil
        if final {
            try await performSeek(value)
        } else {
            optimisticallySetProgress(value)
            let delay = configuration.seekDebounceDelay
            pendingSeekTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                    try await self?.performSeek(value)
                } catch is CancellationError {
                    return
                } catch {
                    self?.eventBus.send(.commandFailed(Self.safeMessage(error)))
                }
            }
        }
    }

    func setVolume(_ percent: Int, final: Bool = true) async throws {
        let value = min(100, max(0, percent))
        pendingVolumeTask?.cancel()
        pendingVolumeTask = nil
        if final {
            try await performVolume(value)
        } else {
            optimisticallySetVolume(value)
            let delay = configuration.volumeDebounceDelay
            pendingVolumeTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                    try await self?.performVolume(value)
                } catch is CancellationError {
                    return
                } catch {
                    self?.eventBus.send(.commandFailed(Self.safeMessage(error)))
                }
            }
        }
    }

    private func performSeek(_ value: Int) async throws {
        try await withReceiverCommand(optimistic: { $0?.progressMS = value }, refreshAfter: false) { deviceID in
            try await self.api.seek(to: value, on: deviceID)
        }
    }

    private func performVolume(_ value: Int) async throws {
        try await withReceiverCommand(optimistic: { playback in
            guard let device = playback?.device else { return }
            playback?.device = Self.copy(device, volumePercent: value)
        }, refreshAfter: false) { deviceID in
            try await self.api.setVolume(value, on: deviceID)
        }
    }

    private func withReceiverCommand(
        optimistic: @escaping (inout PlaybackState?) -> Void = { _ in },
        refreshAfter: Bool = true,
        operation: @escaping (String) async throws -> Void
    ) async throws {
        cancelReceiverRecovery()
        try await serialized {
            let device = try await self.resolveCommandDevice()
            guard let deviceID = device.id else {
                throw PlaybackCoordinatorError.receiverHasNoDeviceID(name: self.receiverName)
            }
            try await self.optimistically(updating: optimistic) {
                try await operation(deviceID)
            }
            if refreshAfter { try await self.refreshAfterCommandIfNeeded() }
        }
    }

    private func serialized(_ operation: () async throws -> Void) async throws {
        await commandGate.acquire()
        do {
            try await operation()
            await commandGate.release()
        } catch {
            await commandGate.release()
            eventBus.send(.commandFailed(Self.safeMessage(error)))
            throw error
        }
    }

    private func optimistically(
        updating mutation: (inout PlaybackState?) -> Void,
        operation: () async throws -> Void
    ) async throws {
        let original = serverPlayback
        mutation(&serverPlayback)
        serverPlaybackTimestamp = clock.now
        eventBus.send(.stateChanged(serverPlayback))
        do {
            try await operation()
        } catch {
            serverPlayback = original
            serverPlaybackTimestamp = clock.now
            eventBus.send(.stateChanged(original))
            throw error
        }
    }

    private func resolveCommandDevice() async throws -> SpotifyDevice {
        let devices = try await api.devices()
        let currentDeviceID = serverPlayback?.device?.id
        let matching = devices.first(where: { device in
            guard let currentDeviceID else { return false }
            return device.id == currentDeviceID
        }) ?? devices.first(where: \.isActive)
            ?? devices.first(where: { $0.name == receiverName })

        guard let matching else {
            throw PlaybackCoordinatorError.activeDeviceNotFound
        }
        if matching.name == receiverName {
            updateReceiver(matching)
        }
        return matching
    }

    private func commandDevice(for playback: PlaybackState) async throws -> SpotifyDevice {
        guard playback.device?.name == receiverName else {
            return try await resolveCommandDevice()
        }

        var device = try await prepareLocalReceiver()
        guard let deviceID = device.id else {
            throw PlaybackCoordinatorError.receiverHasNoDeviceID(name: receiverName)
        }
        if !device.isActive {
            try await api.transferPlayback(to: deviceID, play: false)
            device = try await waitUntilReceiverIsActive(expectedID: deviceID)
        }
        updateReceiver(device)
        return device
    }

    private func prepareLocalReceiver() async throws -> SpotifyDevice {
        try await spotifyd.start()
        do {
            return try await discoverReceiver(
                timeout: min(
                    configuration.receiverDiscoveryTimeout,
                    configuration.receiverRediscoveryTimeoutBeforeRestart
                )
            )
        } catch let error as PlaybackCoordinatorError {
            guard case .receiverNotFound = error else { throw error }
            // A spotifyd process can survive while its Connect session no longer advertises a
            // device. One bounded restart gives it a clean session and a freshly discovered ID.
            await spotifyd.stop()
            try await spotifyd.start()
            return try await discoverReceiver(timeout: configuration.receiverDiscoveryTimeout)
        }
    }

    private func discoverReceiver(timeout: Duration? = nil) async throws -> SpotifyDevice {
        let deadline = clock.now.advanced(by: timeout ?? configuration.receiverDiscoveryTimeout)
        var delay = configuration.initialDiscoveryDelay
        repeat {
            try Task.checkCancellation()
            let devices = try await api.devices()
            if let matching = devices.first(where: { $0.name == receiverName }) {
                updateReceiver(matching)
                return matching
            }
            try await Task.sleep(for: delay)
            delay = min(delay * 2, configuration.maximumDiscoveryDelay)
        } while clock.now < deadline
        throw PlaybackCoordinatorError.receiverNotFound(name: receiverName)
    }

    private func waitUntilReceiverIsActive(expectedID: String) async throws -> SpotifyDevice {
        let deadline = clock.now.advanced(by: configuration.receiverActivationTimeout)
        repeat {
            try Task.checkCancellation()
            let devices = try await api.devices()
            if let matching = devices.first(where: {
                $0.name == receiverName && $0.id == expectedID && $0.isActive
            }) {
                return matching
            }
            try await Task.sleep(for: .milliseconds(250))
        } while clock.now < deadline
        throw PlaybackCoordinatorError.receiverDidNotBecomeActive(name: receiverName)
    }

    private func waitUntilDeviceIsActive(
        expectedID: String,
        name: String,
        timeout: Duration? = nil
    ) async throws -> SpotifyDevice {
        let deadline = clock.now.advanced(by: timeout ?? configuration.receiverActivationTimeout)
        repeat {
            try Task.checkCancellation()
            let devices = try await api.devices()
            if let matching = devices.first(where: { $0.id == expectedID && $0.isActive }) {
                return matching
            }
            try await Task.sleep(for: .milliseconds(250))
        } while clock.now < deadline
        throw PlaybackCoordinatorError.deviceDidNotBecomeActive(name: name)
    }

    private func refreshAfterCommandIfNeeded() async throws {
        guard configuration.refreshAfterCommands else { return }
        _ = try await refresh()
    }

    private func setPlayback(_ state: PlaybackState?) {
        serverPlayback = state
        serverPlaybackTimestamp = clock.now
        eventBus.send(.stateChanged(state))
    }

    private func restore(_ snapshot: PlaybackState, on device: SpotifyDevice) async throws {
        guard let track = snapshot.item,
              let deviceID = device.id else {
            throw PlaybackCoordinatorError.receiverHasNoDeviceID(name: receiverName)
        }

        let position = min(max(0, snapshot.progressMS), track.durationMS)
        let request = Self.restorationRequest(for: snapshot, positionMS: position)
        try await confirmingPlay(for: track.uri) {
            try await optimistically(updating: { playback in
                var restored = snapshot
                restored.progressMS = position
                restored.isPlaying = true
                restored.device = Self.copy(device, isActive: true)
                playback = restored
            }) {
                try await api.play(request, on: deviceID)
            }
            if let activeDevice = serverPlayback?.device {
                updateReceiver(activeDevice)
            }
        }
    }

    private func confirmingPlay(
        for trackURI: String?,
        operation: () async throws -> Void
    ) async throws {
        let previousPendingTrackURI = pendingSelectedTrackURI
        let previousPendingTrackDeadline = pendingSelectedTrackDeadline
        if let trackURI {
            pendingSelectedTrackURI = trackURI
            pendingSelectedTrackDeadline = clock.now.advanced(by: .seconds(12))
        }
        do {
            try await operation()
        } catch {
            pendingSelectedTrackURI = previousPendingTrackURI
            pendingSelectedTrackDeadline = previousPendingTrackDeadline
            throw error
        }
    }

    private static func restorationRequest(
        for snapshot: PlaybackState,
        positionMS: Int
    ) -> PlayRequest {
        guard let track = snapshot.item else { return .resume }
        if let contextURI = snapshot.contextURI,
           contextURI.hasPrefix("spotify:album:") || contextURI.hasPrefix("spotify:playlist:") {
            return .context(uri: contextURI, offsetURI: track.uri, positionMS: positionMS)
        }
        if let albumURI = track.album?.uri {
            return .context(uri: albumURI, offsetURI: track.uri, positionMS: positionMS)
        }
        return .uris([track.uri], positionMS: positionMS)
    }

    private func runReceiverRecovery(
        snapshot: PlaybackState,
        identifier: UUID,
        restartReceiver: Bool
    ) async {
        defer {
            if receiverRecoveryIdentifier == identifier {
                receiverRecoveryTask = nil
                receiverRecoveryIdentifier = nil
            }
        }

        guard let track = snapshot.item else { return }
        let deadline = clock.now.advanced(by: configuration.receiverDiscoveryTimeout)
        var delay = configuration.initialDiscoveryDelay

        do {
            if restartReceiver {
                await spotifyd.stop()
            }
            try await spotifyd.start()
        } catch {
            eventBus.send(.commandFailed(Self.safeMessage(error)))
            return
        }

        while clock.now < deadline {
            guard !Task.isCancelled,
                  receiverRecoveryIdentifier == identifier,
                  serverPlayback?.isPlaying == snapshot.isPlaying,
                  serverPlayback?.item?.uri == track.uri else {
                return
            }

            do {
                if let active = try await api.playbackState(),
                   active.device?.name != receiverName {
                    setPlayback(active)
                    return
                }

                let devices = try await api.devices()
                if let device = devices.first(where: { $0.name == receiverName }),
                   let deviceID = device.id {
                    try Task.checkCancellation()
                    var restored = snapshot
                    let recoveredDevice = Self.copy(device, isActive: snapshot.isPlaying)
                    restored.device = recoveredDevice
                    if snapshot.isPlaying {
                        let position = min(max(0, snapshot.progressMS), track.durationMS)
                        try await confirmingPlay(for: track.uri) {
                            try await api.play(
                                Self.restorationRequest(for: snapshot, positionMS: position),
                                on: deviceID
                            )
                        }
                        restored.progressMS = position
                    }
                    setPlayback(restored)
                    updateReceiver(recoveredDevice)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                // The reconnecting receiver can be advertised before it accepts commands.
                // Retry within the bounded recovery window.
            }

            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            delay = min(delay * 2, configuration.maximumDiscoveryDelay)
        }
    }

    private func cancelReceiverRecovery() {
        receiverRecoveryTask?.cancel()
        receiverRecoveryTask = nil
        receiverRecoveryIdentifier = nil
    }

    private func updateReceiver(_ device: SpotifyDevice) {
        if receiver != device {
            receiver = device
            eventBus.send(.receiverChanged(device))
        }
    }

    private func optimisticallySetProgress(_ value: Int) {
        serverPlayback?.progressMS = value
        serverPlaybackTimestamp = clock.now
        eventBus.send(.stateChanged(serverPlayback))
    }

    private func optimisticallySetVolume(_ value: Int) {
        if let device = serverPlayback?.device {
            serverPlayback?.device = Self.copy(device, volumePercent: value)
        }
        eventBus.send(.stateChanged(serverPlayback))
    }

    private static func copy(
        _ device: SpotifyDevice,
        isActive: Bool? = nil,
        volumePercent: Int? = nil
    ) -> SpotifyDevice {
        SpotifyDevice(
            id: device.id,
            isActive: isActive ?? device.isActive,
            isPrivateSession: device.isPrivateSession,
            isRestricted: device.isRestricted,
            name: device.name,
            type: device.type,
            volumePercent: volumePercent ?? device.volumePercent,
            supportsVolume: device.supportsVolume
        )
    }

    private func runReconciliationLoop() async {
        while observationActivity != .hidden && !Task.isCancelled {
            do {
                _ = try await refresh()
            } catch is CancellationError {
                return
            } catch {
                eventBus.send(.commandFailed(Self.safeMessage(error)))
            }
            do {
                try await Task.sleep(for: configuration.activeRefreshInterval)
            } catch {
                return
            }
        }
    }

    private static func safeMessage(_ error: Error) -> String {
        String((error as NSError).localizedDescription.prefix(512))
    }
}

enum PlaybackObservationActivity: Sendable, Equatable {
    case active
    case hidden
}
