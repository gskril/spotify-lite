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
    @Published var sessionState: AppSessionState = .needsSetup
    @Published var selectedDestination: AppDestination? = .home
    @Published var playback: PlaybackState? {
        didSet { systemMediaController.update(playback: playback) }
    }
    @Published var spotifydState: SpotifydState = .stopped
    @Published var alertMessage: String?
    @Published var presentedPlaylist: SpotifyPlaylistSummary?
    @Published var presentedGeneratedMix: GeneratedMixPresentation?
    @Published private(set) var isStartingPlayback = false
    @Published private(set) var searchFocusRequest = UUID()

    let authorizer: any SpotifyAuthorizing
    let api: any SpotifyAPIProviding
    let spotifyd: any SpotifydManaging
    let playbackCoordinator: PlaybackCoordinator
    private let systemMediaController = SystemMediaController()
    private var keyboardMonitor: Any?

    init(
        authorizer: any SpotifyAuthorizing,
        api: any SpotifyAPIProviding,
        spotifyd: any SpotifydManaging,
        playbackCoordinator: PlaybackCoordinator
    ) {
        self.authorizer = authorizer
        self.api = api
        self.spotifyd = spotifyd
        self.playbackCoordinator = playbackCoordinator
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
            Task { @MainActor [weak self] in self?.togglePlayback() }
            return nil
        }
    }

    func installSystemMediaCommands() {
        systemMediaController.install { [weak self] command in
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
        guard playback?.isPlaying != true else { return }
        playback?.isPlaying = true
        runPlaybackCommand { coordinator, _ in try await coordinator.play() }
    }

    func pause() {
        guard playback?.isPlaying == true else { return }
        playback?.isPlaying = false
        runPlaybackCommand { coordinator, _ in try await coordinator.pause() }
    }

    func playLocally(_ request: PlayRequest, preview: SpotifyTrack? = nil) {
        guard !isStartingPlayback else { return }
        let previousPlayback = playback
        if let preview {
            playback = Self.previewPlayback(for: preview, preserving: previousPlayback)
        }
        runStartingPlayback(preview: preview) { coordinator in
            try await coordinator.playLocally(request, preview: preview)
        }
    }

    func resumeLocally() {
        runStartingPlayback { coordinator in
            try await coordinator.resume()
        }
    }

    func skipNext() {
        runPlaybackCommand { coordinator, _ in try await coordinator.next() }
    }

    func skipPrevious() {
        runPlaybackCommand { coordinator, _ in try await coordinator.previous() }
    }

    func adjustVolume(by delta: Int) {
        let current = playback?.device?.volumePercent ?? 50
        runPlaybackCommand { coordinator, _ in
            try await coordinator.setVolume(min(100, max(0, current + delta)))
        }
    }

    private func runPlaybackCommand(
        _ operation: @escaping @Sendable (PlaybackCoordinator, Bool) async throws -> Void
    ) {
        let isPlaying = playback?.isPlaying == true
        Task {
            do {
                try await operation(playbackCoordinator, isPlaying)
                playback = await playbackCoordinator.currentPlayback()
            } catch {
                playback = await playbackCoordinator.currentPlayback()
                report(error)
            }
        }
    }

    private func runStartingPlayback(
        preview: SpotifyTrack? = nil,
        _ operation: @escaping @Sendable (PlaybackCoordinator) async throws -> Void
    ) {
        guard !isStartingPlayback else { return }
        let previousPlayback = playback
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

    static func previewPlayback(
        for track: SpotifyTrack,
        preserving previousPlayback: PlaybackState?
    ) -> PlaybackState {
        PlaybackState(
            item: track,
            progressMS: 0,
            isPlaying: true,
            device: previousPlayback?.device,
            shuffle: previousPlayback?.shuffle ?? false,
            repeatMode: previousPlayback?.repeatMode ?? .off
        )
    }
}
