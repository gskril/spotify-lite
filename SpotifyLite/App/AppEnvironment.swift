import Foundation
import Combine
import AppKit

enum AppSessionState: Sendable, Equatable {
    case needsSetup
    case authorizing
    case ready(SpotifyUser)
    case failure(String)
}

@MainActor
final class AppEnvironment: ObservableObject {
    @Published var sessionState: AppSessionState = .needsSetup
    @Published var selectedDestination: AppDestination? = .home
    @Published var playback: PlaybackState?
    @Published var spotifydState: SpotifydState = .stopped
    @Published var alertMessage: String?
    @Published var presentedPlaylist: SpotifyPlaylistSummary?
    @Published private(set) var isStartingPlayback = false
    @Published private(set) var searchFocusRequest = UUID()

    let authorizer: any SpotifyAuthorizing
    let api: any SpotifyAPIProviding
    let spotifyd: any SpotifydManaging
    let playbackCoordinator: PlaybackCoordinator
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
        presentedPlaylist = playlist
    }

    func dismissPlaylist() {
        presentedPlaylist = nil
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

    func togglePlayback() {
        let wasPlaying = playback?.isPlaying == true
        playback?.isPlaying = !wasPlaying
        runPlaybackCommand(isPlaying: wasPlaying) { coordinator, isPlaying in
            if isPlaying { try await coordinator.pause() }
            else { try await coordinator.resume() }
        }
    }

    func playLocally(_ request: PlayRequest, preview: SpotifyTrack? = nil) {
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
        isPlaying initialIsPlaying: Bool? = nil,
        _ operation: @escaping @Sendable (PlaybackCoordinator, Bool) async throws -> Void
    ) {
        let isPlaying = initialIsPlaying ?? (playback?.isPlaying == true)
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
        if let preview {
            playback = PlaybackState(
                item: preview,
                progressMS: 0,
                isPlaying: true,
                device: previousPlayback?.device,
                shuffle: previousPlayback?.shuffle ?? false,
                repeatMode: previousPlayback?.repeatMode ?? .off
            )
        }
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
