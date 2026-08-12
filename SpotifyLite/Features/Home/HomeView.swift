import SwiftUI

struct HomeView: View {
    @ObservedObject var environment: AppEnvironment
    let user: SpotifyUser

    @State private var recentTracks: [SpotifyTrack] = []
    @State private var dayMix: [SpotifyTrack] = []
    @State private var playlists: [SpotifyPlaylistSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                welcomeHeader
                receiverBanner

                if isLoading {
                    LoadingView(message: "Building your home mix…")
                        .frame(minHeight: 300)
                } else if let errorMessage, recentTracks.isEmpty && playlists.isEmpty {
                    FeatureStateView(
                        title: "Home is taking a break",
                        message: errorMessage,
                        symbol: "music.note.house",
                        actionTitle: "Try Again",
                        action: load
                    )
                    .frame(minHeight: 300)
                } else {
                    if !dayMix.isEmpty { dayMixHero }
                    if !personalizedPlaylists.isEmpty { playlistRail }
                    if !recentAlbums.isEmpty { albumRail }
                    if !recentTracks.isEmpty { recentRail }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28)
        }
        .task { await loadAsync() }
    }

    private var welcomeHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(greeting)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(user.displayName.map { "Here’s a soundtrack for your \(dayPart), \($0)." } ?? "A soundtrack shaped by what you play.")
                .foregroundStyle(.secondary)
        }
    }

    private var receiverBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: receiverSymbol)
                .foregroundStyle(receiverColor)
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(receiverTitle).fontWeight(.semibold)
                Text(receiverMessage).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            receiverAction
        }
        .spotifyCard()
    }

    @ViewBuilder private var receiverAction: some View {
        switch environment.spotifydState {
        case .stopped:
            Button("Start Receiver", systemImage: "play.fill") { startReceiver() }
                .buttonStyle(.bordered)
        case .notInstalled, .needsAuthentication, .crashed:
            Button("Open Settings", systemImage: "arrow.right") { environment.navigate(to: .settings) }
                .buttonStyle(.bordered)
        case .starting:
            ProgressView().controlSize(.small)
        case .running:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.accent)
                .font(.callout.weight(.medium))
        }
    }

    private var dayMixHero: some View {
        Button { playTracks(dayMix) } label: {
            HStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.accent, .purple, .indigo],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: dayPartSymbol)
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 142, height: 142)
                .shadow(color: AppTheme.accent.opacity(0.2), radius: 16, y: 8)

                VStack(alignment: .leading, spacing: 10) {
                    Text("MADE FOR THIS MOMENT")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(dayMixTitle)
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.leading)
                    Text(dayMixSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Label("Play \(dayMix.count) songs", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(AppTheme.accent)
                }
                Spacer(minLength: 8)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [AppTheme.accent.opacity(0.13), .purple.opacity(0.05)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(dayMixTitle), \(dayMix.count) songs")
    }

    private var playlistRail: some View {
        homeSection(title: "Made for you", subtitle: "Your Spotify mixes and playlists, close at hand") {
            horizontalRail {
                ForEach(personalizedPlaylists) { playlist in
                    PlaylistCard(
                        playlist: playlist,
                        artworkSize: 154,
                        onOpen: { environment.presentPlaylist(playlist) },
                        onPlay: { playContext(playlist.uri) }
                    )
                }
            }
        }
    }

    private var albumRail: some View {
        homeSection(title: "Jump back in", subtitle: "Albums from your recent listening") {
            horizontalRail {
                ForEach(recentAlbums) { album in
                    mediaTile(
                        title: album.name,
                        subtitle: album.artists.map(\.name).joined(separator: ", "),
                        artwork: album.images.artworkURL(forPointSize: 154),
                        symbol: "square.stack"
                    ) { playContext(album.uri) }
                }
            }
        }
    }

    private var recentRail: some View {
        homeSection(title: "Recently played", subtitle: "Pick up where you left off") {
            horizontalRail {
                ForEach(Array(recentTracks.prefix(12))) { track in
                    mediaTile(
                        title: track.name,
                        subtitle: track.artists.map(\.name).joined(separator: ", "),
                        artwork: track.album?.images.artworkURL(forPointSize: 154),
                        symbol: "music.note"
                    ) { playTracks([track]) }
                }
            }
        }
    }

    private func homeSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func horizontalRail<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) { content() }
                .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }

    private func mediaTile(
        title: String,
        subtitle: String,
        artwork: URL?,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    ArtworkView(url: artwork, size: 154, cornerRadius: 11, symbol: symbol)
                    Image(systemName: "play.fill")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(width: 38, height: 38)
                        .background(AppTheme.accent, in: Circle())
                        .shadow(radius: 6, y: 3)
                        .padding(8)
                }
                Text(title).fontWeight(.semibold).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(width: 154, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(title), \(subtitle)")
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var dayPart: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "morning"
        case 12..<18: "afternoon"
        case 18..<23: "evening"
        default: "late night"
        }
    }

    private var dayPartSymbol: String {
        switch dayPart {
        case "morning": "sunrise.fill"
        case "afternoon": "sun.max.fill"
        case "evening": "sunset.fill"
        default: "moon.stars.fill"
        }
    }

    private var dayMixTitle: String {
        let weekday = Date.now.formatted(.dateTime.weekday(.wide))
        return "Your \(weekday) \(dayPart) mix"
    }

    private var dayMixSubtitle: String {
        let artists = HomePersonalizer.artistNames(from: dayMix, limit: 4)
        return artists.isEmpty
            ? "A fresh shuffle based on what you’ve been listening to."
            : "Featuring \(artists.joined(separator: ", ")) and more. Refreshed throughout your week."
    }

    private var personalizedPlaylists: [SpotifyPlaylistSummary] {
        HomePersonalizer.prioritizedPlaylists(playlists, limit: 10)
    }

    private var recentAlbums: [SpotifyAlbumSummary] {
        HomePersonalizer.uniqueAlbums(from: recentTracks, limit: 10)
    }

    private var receiverSymbol: String {
        if case .running = environment.spotifydState { return "hifispeaker.fill" }
        return "hifispeaker"
    }

    private var receiverColor: Color {
        if case .running = environment.spotifydState { return AppTheme.accent }
        if case .crashed = environment.spotifydState { return .red }
        return .secondary
    }

    private var receiverTitle: String {
        switch environment.spotifydState {
        case .running: "Local receiver is running"
        case .starting: "Starting local receiver…"
        case .notInstalled: "Install the local receiver"
        case .needsAuthentication: "Finish receiver sign-in"
        case .crashed: "Receiver needs attention"
        case .stopped: "Local receiver is off"
        }
    }

    private var receiverMessage: String {
        switch environment.spotifydState {
        case .running: "Choose music to connect it to Spotify and start playback."
        case .notInstalled: "One quick Settings step enables lightweight local playback."
        case .needsAuthentication: "Spotify Web API is connected; authenticate spotifyd once to hear audio."
        case .crashed: "Open Settings for the error and a quick retry."
        case .starting: "This usually takes a few seconds."
        case .stopped: "Start it now, or Spotify Lite will start it when you play a song."
        }
    }

    private func cleanDescription(_ description: String?) -> String? {
        guard let description else { return nil }
        let stripped = description.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    private func load() { Task { await loadAsync() } }

    private func loadAsync() async {
        isLoading = true
        errorMessage = nil
        do {
            async let loadedTracks = environment.api.recentlyPlayed()
            async let loadedPlaylists = environment.api.currentUserPlaylists()
            let (tracks, userPlaylists) = try await (loadedTracks, loadedPlaylists)
            recentTracks = HomePersonalizer.uniqueTracks(tracks)
            playlists = userPlaylists
            dayMix = HomePersonalizer.dayMix(from: recentTracks, date: .now)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func playTracks(_ tracks: [SpotifyTrack]) {
        let uris = tracks.map(\.uri)
        guard !uris.isEmpty else { return }
        environment.playLocally(.uris(uris), preview: tracks.first)
    }

    private func playContext(_ uri: String) {
        environment.playLocally(.context(uri: uri))
    }

    private func startReceiver() {
        environment.spotifydState = .starting
        Task {
            do { try await environment.spotifyd.start() }
            catch SpotifydSupervisorError.authenticationRequired {
                environment.spotifydState = .needsAuthentication
            }
            catch {
                environment.spotifydState = .crashed(status: -1)
                environment.report(error)
            }
        }
    }
}

enum HomePersonalizer {
    static func uniqueTracks(_ tracks: [SpotifyTrack]) -> [SpotifyTrack] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    static func dayMix(from tracks: [SpotifyTrack], date: Date, limit: Int = 20) -> [SpotifyTrack] {
        let unique = uniqueTracks(tracks)
        guard unique.count > 1 else { return unique }
        let bucket = date.formatted(.dateTime.year().month().day().hour(.twoDigits(amPM: .omitted)))
        return unique.sorted { stableScore($0.id + bucket) < stableScore($1.id + bucket) }
            .prefix(limit)
            .map { $0 }
    }

    static func prioritizedPlaylists(
        _ playlists: [SpotifyPlaylistSummary],
        limit: Int
    ) -> [SpotifyPlaylistSummary] {
        let signals = [
            "daylist", "daily mix", "discover weekly", "release radar",
            "on repeat", "repeat rewind", "made for", "mix"
        ]
        let personalized = playlists.filter { playlist in
            let text = "\(playlist.name) \(playlist.description ?? "")".lowercased()
            return signals.contains { text.contains($0) }
        }
        let remainder = playlists.filter { candidate in !personalized.contains(where: { $0.id == candidate.id }) }
        return Array((personalized + remainder).prefix(limit))
    }

    static func uniqueAlbums(from tracks: [SpotifyTrack], limit: Int) -> [SpotifyAlbumSummary] {
        var seen = Set<String>()
        return tracks.compactMap(\.album)
            .filter { seen.insert($0.id).inserted }
            .prefix(limit)
            .map { $0 }
    }

    static func artistNames(from tracks: [SpotifyTrack], limit: Int) -> [String] {
        var seen = Set<String>()
        return tracks.flatMap(\.artists).map(\.name)
            .filter { seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }

    private static func stableScore(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}
