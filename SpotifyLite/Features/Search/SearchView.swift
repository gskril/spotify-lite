import SwiftUI

struct SearchView: View {
    @ObservedObject var environment: AppEnvironment
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Search")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                TextField("Artists, songs, albums, or playlists", text: $query)
                    .focused($searchFieldFocused)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .onSubmit { scheduleSearch(immediate: true) }
                    .onChange(of: query) { _, _ in scheduleSearch(immediate: false) }
            }
            .padding(28)

            Divider()

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptySearchPrompt
            } else if isSearching {
                LoadingView(message: "Searching Spotify…")
            } else if let errorMessage {
                FeatureStateView(title: "Search unavailable", message: errorMessage, symbol: "wifi.exclamationmark", actionTitle: "Try Again") { scheduleSearch(immediate: true) }
            } else if isEmpty {
                FeatureStateView(title: "No results", message: "Try a different spelling or a broader search.", symbol: "magnifyingglass")
            } else {
                resultsView
            }
        }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: environment.searchFocusRequest) { _, _ in searchFieldFocused = true }
    }

    private var emptySearchPrompt: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Find your next listen")
                    .font(.title2.bold())
                Text("Search Spotify's catalog for tracks, albums, artists, and playlists.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var isEmpty: Bool {
        results.tracks.isEmpty && results.albums.isEmpty && results.artists.isEmpty && results.playlists.isEmpty
    }

    private var resultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !results.tracks.isEmpty {
                    resultSection("Songs") {
                        VStack(spacing: 4) {
                            ForEach(results.tracks) { track in
                                TrackRow(track: track) { playTrack(track) }
                                if track.id != results.tracks.last?.id { Divider() }
                            }
                        }
                    }
                }
                if !results.albums.isEmpty {
                    resultSection("Albums") { horizontalAlbums }
                }
                if !results.artists.isEmpty {
                    resultSection("Artists") { horizontalArtists }
                }
                if !results.playlists.isEmpty {
                    resultSection("Playlists") { horizontalPlaylists }
                }
            }
            .padding(28)
        }
    }

    private func resultSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            content()
        }
    }

    private var horizontalAlbums: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(results.albums) { album in
                    resultTile(title: album.name, subtitle: album.artists.map(\.name).joined(separator: ", "), url: album.images.artworkURL(forPointSize: 132), symbol: "square.stack") {
                        playContext(album.uri)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var horizontalArtists: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(results.artists) { artist in
                    resultTile(title: artist.name, subtitle: "Artist", url: artist.images?.first?.url, symbol: "person.fill") {
                        if let uri = artist.uri { playContext(uri) }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var horizontalPlaylists: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(results.playlists) { playlist in
                    PlaylistCard(
                        playlist: playlist,
                        artworkSize: 132,
                        onOpen: { environment.presentPlaylist(playlist) },
                        onPlay: { playContext(playlist.uri) }
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func resultTile(title: String, subtitle: String, url: URL?, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(url: url, size: 132, cornerRadius: 9, symbol: symbol)
                Text(title).fontWeight(.semibold).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 132, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func scheduleSearch(immediate: Bool) {
        searchTask?.cancel()
        let currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentQuery.isEmpty else {
            results = .init()
            isSearching = false
            return
        }
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            isSearching = true
            errorMessage = nil
            do {
                results = try await environment.api.search(currentQuery, types: Set(SearchType.allCases))
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func playTrack(_ track: SpotifyTrack) {
        environment.playLocally(.uris([track.uri]), preview: track)
    }

    private func playContext(_ uri: String) {
        environment.playLocally(.context(uri: uri))
    }
}
