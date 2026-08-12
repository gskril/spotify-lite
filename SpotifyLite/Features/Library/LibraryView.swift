import SwiftUI

struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case tracks = "Liked Songs"
        case albums = "Albums"
        case playlists = "Playlists"
        var id: Self { self }
    }

    @ObservedObject var environment: AppEnvironment
    @State private var selection: Section = .tracks
    @State private var tracks: [SpotifyTrack] = []
    @State private var albums: [SpotifyAlbumSummary] = []
    @State private var playlists: [SpotifyPlaylistSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Your Library")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Spacer()
                Picker("Library section", selection: $selection) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)

            Divider()

            Group {
                if isLoading {
                    LoadingView(message: "Loading your library…")
                } else if let errorMessage {
                    FeatureStateView(title: "Library unavailable", message: errorMessage, symbol: "wifi.exclamationmark", actionTitle: "Try Again") { load() }
                } else {
                    content
                }
            }
        }
        .task { await loadAsync() }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .tracks:
            if tracks.isEmpty { emptyView(for: selection) }
            else {
                List(tracks) { track in
                    TrackRow(track: track) { play(track) }
                }
                .listStyle(.inset)
            }
        case .albums:
            if albums.isEmpty { emptyView(for: selection) }
            else { collectionGrid(albums.map { ($0.id, $0.name, $0.artists.map(\.name).joined(separator: ", "), $0.images.first?.url, $0.uri, "square.stack") }) }
        case .playlists:
            if playlists.isEmpty { emptyView(for: selection) }
            else { playlistGrid }
        }
    }

    private func emptyView(for section: Section) -> some View {
        FeatureStateView(
            title: "No \(section.rawValue.lowercased()) yet",
            message: section == .tracks ? "Songs you like will appear here." : "Save something in Spotify and it will appear here.",
            symbol: section == .tracks ? "heart" : "square.stack"
        )
    }

    private func collectionGrid(_ items: [(String, String, String, URL?, String, String)]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 18)], spacing: 22) {
                ForEach(items, id: \.0) { item in
                    Button { playContext(item.4) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            ArtworkView(url: item.3, size: 148, cornerRadius: 10, symbol: item.5)
                                .frame(maxWidth: .infinity)
                            Text(item.1).fontWeight(.semibold).lineLimit(1)
                            Text(item.2).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(28)
        }
    }

    private var playlistGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 18)], spacing: 22) {
                ForEach(playlists) { playlist in
                    PlaylistCard(
                        playlist: playlist,
                        artworkSize: 148,
                        onOpen: { environment.presentPlaylist(playlist) },
                        onPlay: { playContext(playlist.uri) }
                    )
                }
            }
            .padding(28)
        }
    }

    private func load() { Task { await loadAsync() } }

    private func loadAsync() async {
        isLoading = true
        errorMessage = nil
        do {
            async let loadedTracks = environment.api.savedTracks()
            async let loadedAlbums = environment.api.savedAlbums()
            async let loadedPlaylists = environment.api.currentUserPlaylists()
            (tracks, albums, playlists) = try await (loadedTracks, loadedAlbums, loadedPlaylists)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func play(_ track: SpotifyTrack) {
        environment.playLocally(.uris([track.uri]), preview: track)
    }

    private func playContext(_ uri: String) {
        environment.playLocally(.context(uri: uri))
    }
}
