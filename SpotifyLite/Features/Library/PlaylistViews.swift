import SwiftUI

struct PlaylistCard: View {
    let playlist: SpotifyPlaylistSummary
    let artworkSize: CGFloat
    let onOpen: () -> Void
    let onPlay: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    ArtworkView(
                        url: playlist.images.artworkURL(forPointSize: artworkSize),
                        size: artworkSize,
                        cornerRadius: 10,
                        symbol: "music.note.list"
                    )
                    Text(playlist.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(playlist.description?.nilIfEmpty ?? "Playlist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(width: artworkSize, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(playlist.name)")

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.accent, in: Circle())
                    .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
            }
            .buttonStyle(.plain)
            .help("Play \(playlist.name)")
            .padding(.trailing, 8)
            .padding(.bottom, 52)
        }
    }
}

struct PlaylistDetailView: View {
    @ObservedObject var environment: AppEnvironment
    let playlist: SpotifyPlaylistSummary
    let onDismiss: () -> Void

    @State private var detail: SpotifyPlaylistDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isStartingPlaylist = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                HStack(alignment: .center, spacing: 20) {
                    ArtworkView(
                        url: displayedPlaylist.images.artworkURL(forPointSize: 152),
                        size: 132,
                        cornerRadius: 10,
                        symbol: "music.note.list"
                    )
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 5)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("PLAYLIST")
                            .font(.caption2.bold())
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        Text(displayedPlaylist.name)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let description = displayedPlaylist.description?.nilIfEmpty {
                            Text(description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Button {
                            isStartingPlaylist = true
                            environment.playLocally(
                                .context(uri: displayedPlaylist.uri),
                                preview: tracks.first
                            )
                            Task {
                                try? await Task.sleep(for: .milliseconds(700))
                                isStartingPlaylist = false
                            }
                        } label: {
                            HStack(spacing: 7) {
                                if isStartingPlaylist {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.black)
                                } else {
                                    Image(systemName: "play.fill")
                                }
                                Text(isStartingPlaylist ? "Starting…" : "Play")
                            }
                        }
                        .buttonStyle(PlaylistPrimaryButtonStyle())
                        .disabled(isStartingPlaylist || environment.isStartingPlayback)
                        .padding(.top, 5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(22)
                .padding(.trailing, 54)

                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .padding(.top, 18)
                    .padding(.trailing, 20)
            }
            .background {
                LinearGradient(
                    colors: [AppTheme.accent.opacity(0.09), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            Divider()

            Group {
                if isLoading {
                    LoadingView(message: "Loading playlist songs…")
                } else if let errorMessage {
                    FeatureStateView(
                        title: "Playlist unavailable",
                        message: errorMessage,
                        symbol: "lock.trianglebadge.exclamationmark",
                        actionTitle: "Try Again"
                    ) { load() }
                } else if detail?.itemAccess == .restricted {
                    FeatureStateView(
                        title: "Songs hidden by Spotify",
                        message: "Development Mode only reveals songs for playlists you own or collaborate on. You can still play this playlist.",
                        symbol: "eye.slash"
                    )
                } else if tracks.isEmpty {
                    FeatureStateView(
                        title: "This playlist is empty",
                        message: "There aren't any songs in this playlist yet.",
                        symbol: "music.note.list"
                    )
                } else {
                    NumberedTrackList(tracks: tracks) { track, _ in
                        environment.playLocally(
                            .context(uri: displayedPlaylist.uri, offsetURI: track.uri),
                            preview: track
                        )
                    }
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 650)
        .task { await loadAsync() }
    }

    private var displayedPlaylist: SpotifyPlaylistSummary { detail?.summary ?? playlist }
    private var tracks: [SpotifyTrack] { detail?.tracks ?? [] }

    private func load() {
        Task { await loadAsync() }
    }

    private func loadAsync() async {
        isLoading = true
        errorMessage = nil
        do {
            detail = try await environment.api.playlistDetail(for: playlist)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct PlaylistPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black.opacity(isEnabled ? 0.92 : 0.48))
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(
                AppTheme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.34),
                in: Capsule()
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
