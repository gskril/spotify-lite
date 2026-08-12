import Foundation
import MediaPlayer

enum SystemMediaCommand: Sendable, Equatable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
}

@MainActor
final class SystemMediaController {
    typealias CommandHandler = @MainActor (SystemMediaCommand) -> Void

    private let commandCenter: MPRemoteCommandCenter
    private let nowPlayingCenter: MPNowPlayingInfoCenter
    private var commandHandler: CommandHandler?
    private var targets: [(command: MPRemoteCommand, target: Any)] = []

    init(
        commandCenter: MPRemoteCommandCenter = .shared(),
        nowPlayingCenter: MPNowPlayingInfoCenter = .default()
    ) {
        self.commandCenter = commandCenter
        self.nowPlayingCenter = nowPlayingCenter
    }

    func install(commandHandler: @escaping CommandHandler) {
        self.commandHandler = commandHandler
        guard targets.isEmpty else { return }

        register(commandCenter.playCommand, action: .play)
        register(commandCenter.pauseCommand, action: .pause)
        register(commandCenter.togglePlayPauseCommand, action: .togglePlayPause)
        register(commandCenter.nextTrackCommand, action: .nextTrack)
        register(commandCenter.previousTrackCommand, action: .previousTrack)

        commandCenter.stopCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
    }

    func update(playback: PlaybackState?) {
        let hasTrack = playback?.item != nil
        let isPlaying = playback?.isPlaying == true

        commandCenter.playCommand.isEnabled = hasTrack && !isPlaying
        commandCenter.pauseCommand.isEnabled = hasTrack && isPlaying
        commandCenter.togglePlayPauseCommand.isEnabled = hasTrack
        commandCenter.nextTrackCommand.isEnabled = hasTrack
        commandCenter.previousTrackCommand.isEnabled = hasTrack

        nowPlayingCenter.nowPlayingInfo = Self.nowPlayingInfo(for: playback)
        nowPlayingCenter.playbackState = hasTrack
            ? (isPlaying ? .playing : .paused)
            : .stopped
    }

    static func nowPlayingInfo(for playback: PlaybackState?) -> [String: Any]? {
        guard let playback, let track = playback.item else { return nil }

        let duration = Double(track.durationMS) / 1_000
        let elapsed = min(Double(playback.progressMS) / 1_000, duration)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.artists.map(\.name).joined(separator: ", "),
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: playback.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.uri,
            MPNowPlayingInfoPropertyServiceIdentifier: "spotify"
        ]
        if let albumName = track.album?.name {
            info[MPMediaItemPropertyAlbumTitle] = albumName
        }
        return info
    }

    private func register(_ command: MPRemoteCommand, action: SystemMediaCommand) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.commandHandler?(action)
            }
            return .success
        }
        targets.append((command, target))
    }
}
