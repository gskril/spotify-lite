import Foundation
import Combine
import AppKit

enum AppSessionState: Sendable, Equatable {
    case needsSetup
    case authorizing
    case ready(SpotifyUser)
    case failure(String)
}

struct GeneratedMixPresentation: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    let tracks: [SpotifyTrack]
}

@MainActor
final class AppEnvironment: ObservableObject {
    @Published var sessionState: AppSessionState = .needsSetup {
        didSet {
            if case .ready = sessionState { return }
            browseCache.clear()
        }
    }
    @Published var selectedDestination: AppDestination? = .home
    @Published var playback: PlaybackState? {
        didSet {
            systemMediaController.update(playback: playback)
            if case .ready(let user) = sessionState {
                playbackMemoryStore.save(playback, for: user.id)
            }
        }
    }
    @Published private(set) var spotifydState: SpotifydState = .stopped
    @Published var alertMessage: String?
    @Published var presentedPlaylist: SpotifyPlaylistSummary?
    @Published var presentedGeneratedMix: GeneratedMixPresentation?
    @Published private(set) var isStartingPlayback = false
    @Published private(set) var searchFocusRequest = UUID()

    let authorizer: any SpotifyAuthorizing
    let api: any SpotifyAPIProviding
    let spotifyd: any SpotifydManaging
    let playbackCoordinator: PlaybackCoordinator
    let browseCache = BrowseCache()
    private let systemMediaController = SystemMediaController()
    private let playbackMemoryStore: PlaybackMemoryStore
    private var keyboardMonitor: Any?

    init(
        authorizer: any SpotifyAuthorizing,
        api: any SpotifyAPIProviding,
        spotifyd: any SpotifydManaging,
        playbackCoordinator: PlaybackCoordinator,
        playbackMemoryStore: PlaybackMemoryStore = .init()
    ) {
        self.authorizer = authorizer
        self.api = api
        self.spotifyd = spotifyd
        self.playbackCoordinator = playbackCoordinator
        self.playbackMemoryStore = playbackMemoryStore
    }

    func rememberedPlayback(for accountID: String) -> PlaybackState? {
        playbackMemoryStore.load(for: accountID)
    }

    func clearRememberedPlayback() {
        playbackMemoryStore.clear()
    }

    func report(_ error: Error) {
        alertMessage = error.localizedDescription
    }

    func navigate(to destination: AppDestination) {
        selectedDestination = destination
        if destination == .search { searchFocusRequest = UUID() }
    }

    func requestSearchFocus() {
        navigate(to: .search)
    }

    func presentPlaylist(_ playlist: SpotifyPlaylistSummary) {
        presentedGeneratedMix = nil
        presentedPlaylist = playlist
    }

    func dismissPlaylist() {
        presentedPlaylist = nil
    }

    func presentGeneratedMix(
        title: String,
        subtitle: String,
        symbol: String,
        tracks: [SpotifyTrack]
    ) {
        presentedPlaylist = nil
        presentedGeneratedMix = GeneratedMixPresentation(
            title: title,
            subtitle: subtitle,
            symbol: symbol,
            tracks: tracks
        )
    }

    func dismissGeneratedMix() {
        presentedGeneratedMix = nil
    }

    func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 49, modifiers.isEmpty, !event.isARepeat else { return event }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            DiagnosticLog.shared.record("input.space")
            Task { @MainActor [weak self] in self?.togglePlayback() }
            return nil
        }
    }

    func installSystemMediaCommands() {
        systemMediaController.install { [weak self] command in
            DiagnosticLog.shared.record("input.media_key", ["command": String(describing: command)])
            switch command {
            case .play: self?.play()
            case .pause: self?.pause()
            case .togglePlayPause: self?.togglePlayback()
            case .nextTrack: self?.skipNext()
            case .previousTrack: self?.skipPrevious()
            }
        }
        systemMediaController.update(playback: playback)
    }

    func togglePlayback() {
        if playback?.isPlaying == true { pause() }
        else { play() }
    }

    func play() {
        guard playback?.isPlaying != true, !isStartingPlayback else { return }
        runStartingPlayback { coordinator in try await coordinator.play() }
    }

    func pause() {
        guard playback?.isPlaying == true else { return }
        playback?.isPlaying = false
        runPlaybackCommand { try await $0.pause() }
    }

    func playLocally(_ request: PlayRequest, preview: SpotifyTrack? = nil) {
        guard !isStartingPlayback else { return }
        let previousPlayback = playback
        if let preview {
            playback = .preview(preview, preserving: previousPlayback)
        }
        runStartingPlayback(restoringOnFailure: previousPlayback) { coordinator in
            try await coordinator.playLocally(request, preview: preview)
        }
    }

    func skipNext() {
        runPlaybackCommand { try await $0.next() }
    }

    func skipPrevious() {
        runPlaybackCommand { try await $0.previous() }
    }

    func setShuffle(_ enabled: Bool) {
        runPlaybackCommand { try await $0.setShuffle(enabled) }
    }

    func cycleRepeat() {
        let next = (playback?.repeatMode ?? .off).next
        runPlaybackCommand { try await $0.setRepeat(next) }
    }

    func setVolume(_ percent: Int) {
        let value = min(100, max(0, percent))
        runPlaybackCommand { try await $0.setVolume(value) }
    }

    func adjustVolume(by delta: Int) {
        setVolume((playback?.device?.volumePercent ?? 50) + delta)
    }

    /// Seeks and waits for the result, so a scrubber can resync to the confirmed position.
    func seek(to milliseconds: Int) async {
        await performPlaybackCommand { try await $0.seek(to: milliseconds) }
    }

    func availableDevices() async throws -> [SpotifyDevice] {
        try await playbackCoordinator.availableDevices()
    }

    /// Throws instead of alerting so the device picker can show the failure in place.
    func transferPlayback(to device: SpotifyDevice) async throws {
        try await playbackCoordinator.transferPlayback(to: device)
        playback = await playbackCoordinator.currentPlayback()
    }

    /// Starts the receiver and keeps it alive, optionally stopping it first. `spotifydState`
    /// follows the supervisor's events; this only surfaces the error.
    func startReceiver(restart: Bool = false) async throws {
        if restart { await spotifyd.stop() }
        try await spotifyd.startKeepingAlive()
    }

    /// Mirrors receiver state and forwards receiver events to playback for the app's lifetime.
    func observeReceiver() async {
        // Subscribe before inspecting so the installation state it reports is not missed.
        let events = spotifyd.events
        _ = await spotifyd.inspectInstallation()
        for await event in events {
            guard !Task.isCancelled else { return }
            if case .stateChanged(let state) = event { spotifydState = state }
            await playbackCoordinator.handleReceiverEvent(event)
        }
    }

    /// Mirrors coordinator playback state for the app's lifetime.
    func observePlayback() async {
        for await event in playbackCoordinator.events {
            guard !Task.isCancelled else { return }
            switch event {
            case .stateChanged(let state):
                if isStartingPlayback, state == nil { continue }
                playback = state
            case .receiverChanged(let device):
                if let device, playback != nil {
                    playback?.device = device
                }
            case .commandFailed:
                // Awaited commands already report their own errors.
                break
            }
        }
    }

    private func runPlaybackCommand(
        _ operation: @escaping @Sendable (PlaybackCoordinator) async throws -> Void
    ) {
        Task { await performPlaybackCommand(operation) }
    }

    private func performPlaybackCommand(
        _ operation: @Sendable (PlaybackCoordinator) async throws -> Void
    ) async {
        do {
            try await operation(playbackCoordinator)
            playback = await playbackCoordinator.currentPlayback()
        } catch {
            playback = await playbackCoordinator.currentPlayback()
            report(error)
        }
    }

    /// Runs a command that may launch the local receiver. On failure the player falls back
    /// to the coordinator's state, or to `previousPlayback` when the coordinator has none.
    private func runStartingPlayback(
        _ operation: @escaping @Sendable (PlaybackCoordinator) async throws -> Void
    ) {
        runStartingPlayback(restoringOnFailure: playback, operation)
    }

    private func runStartingPlayback(
        restoringOnFailure previousPlayback: PlaybackState?,
        _ operation: @escaping @Sendable (PlaybackCoordinator) async throws -> Void
    ) {
        guard !isStartingPlayback else { return }
        isStartingPlayback = true
        Task {
            defer { isStartingPlayback = false }
            do {
                try await operation(playbackCoordinator)
                if let updated = await playbackCoordinator.currentPlayback() {
                    playback = updated
                }
            } catch {
                playback = await playbackCoordinator.currentPlayback() ?? previousPlayback
                report(error)
            }
        }
    }
}
