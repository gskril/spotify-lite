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
    @State private var loadedSections = Set<Section>()
    @State private var loadingSections = Set<Section>()
    @State private var nextPages: [Section: URL] = [:]
    @State private var errors: [Section: String] = [:]

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
                if isInitialLoad {
                    LoadingView(message: "Loading (selection.rawValue.lowercased())…")
                } else if let errorMessage = errors[selection], itemsAreEmpty(for: selection) {
                    FeatureStateView(title: "Library unavailable", message: errorMessage, symbol: "wifi.exclamationmark", actionTitle: "Try Again") { reload(selection) }
                } else {
                    content
                }
            }
        }
        .task(id: selection) { await loadSelectedSectionIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .tracks:
            if tracks.isEmpty { emptyView(for: selection) }
            else {
                List {
                    ForEach(tracks) { track in
                        TrackRow(track: track) { play(track) }
                            .onAppear { loadMoreIfNeeded(for: .tracks, itemID: track.id) }
                    }
                    paginationStatus(for: .tracks)
                }
                .listStyle(.inset)
            }
        case .albums:
            if albums.isEmpty { emptyView(for: selection) }
            else { collectionGrid(albums.map { ($0.id, $0.name, $0.artists.map(\.name).joined(separator: ", "), $0.images.artworkURL(forPointSize: 148), $0.uri, "square.stack") }, section: .albums) }
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

    private func collectionGrid(_ items: [(String, String, String, URL?, String, String)], section: Section) -> some View {
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
                    .onAppear { loadMoreIfNeeded(for: section, itemID: item.0) }
                }
            }
            paginationStatus(for: section)
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
                    .onAppear { loadMoreIfNeeded(for: .playlists, itemID: playlist.id) }
                }
            }
            paginationStatus(for: .playlists)
            .padding(28)
        }
    }

    private var isInitialLoad: Bool {
        loadingSections.contains(selection) && !loadedSections.contains(selection)
    }

    private func itemsAreEmpty(for section: Section) -> Bool {
        switch section {
        case .tracks: tracks.isEmpty
        case .albums: albums.isEmpty
        case .playlists: playlists.isEmpty
        }
    }

    private func reload(_ section: Section) {
        loadedSections.remove(section)
        nextPages[section] = nil
        errors[section] = nil
        Task { await loadSection(section, replacing: true) }
    }

    private func loadSelectedSectionIfNeeded() async {
        guard !loadedSections.contains(selection) else { return }
        await loadSection(selection, replacing: true)
    }

    private func loadMoreIfNeeded(for section: Section, itemID: String) {
        guard section == selection,
              nextPages[section] != nil,
              !loadingSections.contains(section),
              trailingIDs(for: section).contains(itemID) else { return }
        Task { await loadSection(section, replacing: false) }
    }

    private func trailingIDs(for section: Section) -> Set<String> {
        let ids: [String]
        switch section {
        case .tracks: ids = tracks.suffix(8).map(\.id)
        case .albums: ids = albums.suffix(8).map(\.id)
        case .playlists: ids = playlists.suffix(8).map(\.id)
        }
        return Set(ids)
    }

    @ViewBuilder
    private func paginationStatus(for section: Section) -> some View {
        if loadedSections.contains(section), loadingSections.contains(section) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading more…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if loadedSections.contains(section), errors[section] != nil {
            Button("Couldn’t load more — Try Again") {
                errors[section] = nil
                Task { await loadSection(section, replacing: false) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private func loadSection(_ section: Section, replacing: Bool) async {
        guard !loadingSections.contains(section) else { return }
        loadingSections.insert(section)
        errors[section] = nil
        let next = replacing ? nil : nextPages[section]
        do {
            switch section {
            case .tracks:
                let page = try await environment.api.savedTracksPage(after: next)
                tracks = replacing ? page.items : tracks + page.items
                nextPages[section] = page.next
            case .albums:
                let page = try await environment.api.savedAlbumsPage(after: next)
                albums = replacing ? page.items : albums + page.items
                nextPages[section] = page.next
            case .playlists:
                let page = try await environment.api.currentUserPlaylistsPage(after: next)
                playlists = replacing ? page.items : playlists + page.items
                nextPages[section] = page.next
            }
            loadedSections.insert(section)
        } catch is CancellationError {
            loadingSections.remove(section)
            return
        } catch {
            errors[section] = error.localizedDescription
        }
        loadingSections.remove(section)
    }

    private func play(_ track: SpotifyTrack) {
        environment.playLocally(.uris([track.uri]), preview: track)
    }

    private func playContext(_ uri: String) {
        environment.playLocally(.context(uri: uri))
    }
}
