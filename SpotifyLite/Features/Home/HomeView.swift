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
                if shouldShowReceiverPrompt {
                    receiverStartPrompt
                }

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
                    if !madeForYouPlaylists.isEmpty { madeForYouRail }
                    if !jumpBackInPlaylists.isEmpty { jumpBackInRail }
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

    private var receiverStartPrompt: some View {
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

    private var shouldShowReceiverPrompt: Bool {
        if case .running = environment.spotifydState { return false }
        return true
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
            EmptyView()
        }
    }

    private var dayMixHero: some View {
        Button {
            environment.presentGeneratedMix(
                title: dayMixTitle,
                subtitle: dayMixSubtitle,
                symbol: dayPartSymbol,
                tracks: dayMix
            )
        } label: {
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
                    Label("View \(dayMix.count) songs", systemImage: "list.bullet")
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
        .accessibilityLabel("Open \(dayMixTitle), \(dayMix.count) songs")
    }

    private var madeForYouRail: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 1) {
                Text("MADE FOR")
                    .font(.caption2.bold())
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Text(madeForName)
                    .font(.title2.bold())
            }
            horizontalRail {
                ForEach(madeForYouPlaylists) { playlist in
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

    private var jumpBackInRail: some View {
        homeSection(title: "Jump back in", subtitle: "More playlists from your library") {
            horizontalRail {
                ForEach(jumpBackInPlaylists) { playlist in
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

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var madeForName: String {
        let name = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name ?? "You" : "You"
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

    private var madeForYouPlaylists: [SpotifyPlaylistSummary] {
        HomePersonalizer.spotifyGeneratedPlaylists(playlists, limit: 12)
    }

    private var jumpBackInPlaylists: [SpotifyPlaylistSummary] {
        HomePersonalizer.jumpBackInPlaylists(playlists, limit: 12)
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
        case .running: "Local receiver is ready"
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

    static func spotifyGeneratedPlaylists(
        _ playlists: [SpotifyPlaylistSummary],
        limit: Int
    ) -> [SpotifyPlaylistSummary] {
        Array(playlists.filter(isSpotifyGenerated).prefix(limit))
    }

    static func jumpBackInPlaylists(
        _ playlists: [SpotifyPlaylistSummary],
        limit: Int
    ) -> [SpotifyPlaylistSummary] {
        Array(playlists.filter { !isSpotifyGenerated($0) }.prefix(limit))
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

    private static func isSpotifyGenerated(_ playlist: SpotifyPlaylistSummary) -> Bool {
        let name = normalized(playlist.name)
        let description = normalized(playlist.description ?? "")
        let ownerID = normalized(playlist.owner?.id ?? "")
        let ownerName = normalized(playlist.owner?.displayName ?? "")
        let isSpotifyOwned = ownerID == "spotify" || ownerName == "spotify"

        // These titles identify Spotify's personalized staples even when older or
        // restricted payloads omit owner metadata.
        let knownTitle = name == "discover weekly"
            || name == "release radar"
            || name == "on repeat"
            || name == "repeat rewind"
            || name == "your time capsule"
            || name.hasSuffix(" daylist")
            || name.range(of: #"^daily mix [1-9][0-9]*$"#, options: .regularExpression) != nil
        if knownTitle { return true }

        guard isSpotifyOwned else { return false }
        return name.contains("daylist")
            || name.contains("daily mix")
            || name.contains("discover weekly")
            || name.contains("release radar")
            || name.contains("on repeat")
            || name.contains("repeat rewind")
            || name.contains("time capsule")
            || name.contains("your top songs")
            || name.hasSuffix(" mix")
            || description.contains("daylist")
            || description.contains("made for")
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
