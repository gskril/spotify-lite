import SwiftUI

struct RootView: View {
    @ObservedObject var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SpotifyLitePreferences.clientIDKey) private var clientID = ""
    @AppStorage(SpotifyLitePreferences.premiumConfirmedKey) private var premiumConfirmed = false
    @AppStorage(SpotifyLitePreferences.autoStartReceiverKey) private var autoStartReceiver = false
    @State private var didBootstrap = false

    var body: some View {
        ZStack {
            Group {
                if case .ready(let user) = environment.sessionState {
                    mainApp(user: user)
                } else {
                    OnboardingView(environment: environment)
                }
            }

            if let playlist = environment.presentedPlaylist {
                PlaylistModalLayer(
                    environment: environment,
                    playlist: playlist,
                    onDismiss: environment.dismissPlaylist
                )
                .zIndex(10)
            }

            if let mix = environment.presentedGeneratedMix {
                GeneratedMixModalLayer(
                    environment: environment,
                    mix: mix,
                    onDismiss: environment.dismissGeneratedMix
                )
                .zIndex(10)
            }
        }
        .tint(AppTheme.accent)
        .task { await bootstrapIfPossible() }
        .task { await observeReceiver() }
        .task { await observePlayback() }
        .task { environment.installKeyboardMonitor() }
        .task { environment.installSystemMediaCommands() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            Task {
                guard case .ready = environment.sessionState else {
                    await environment.playbackCoordinator.setObservationActivity(.hidden)
                    return
                }
                await environment.playbackCoordinator.setObservationActivity(
                    phase == .active ? .active : .hidden
                )
            }
        }
        .onChange(of: environment.sessionState) { _, state in
            guard case .ready(let user) = state else {
                Task { await environment.playbackCoordinator.setObservationActivity(.hidden) }
                return
            }
            Task {
                do {
                    environment.playback = try await environment.playbackCoordinator.hydrateFromAccountHistory(
                        rememberedPlayback: environment.rememberedPlayback(for: user.id)
                    )
                } catch {
                    // Playback history is helpful startup state, not a reason to block the app.
                }
                await environment.playbackCoordinator.setObservationActivity(
                    scenePhase == .active ? .active : .hidden
                )
            }
            guard autoStartReceiver else { return }
            Task {
                do { try await environment.spotifyd.start() }
                catch SpotifydSupervisorError.authenticationRequired {
                    environment.spotifydState = .needsAuthentication
                } catch { environment.report(error) }
            }
        }
        .alert("Spotify Lite", isPresented: Binding(
            get: { environment.alertMessage != nil },
            set: { if !$0 { environment.alertMessage = nil } }
        )) {
            Button("OK") { environment.alertMessage = nil }
        } message: {
            Text(environment.alertMessage ?? "An unexpected error occurred.")
        }
    }

    private func mainApp(user: SpotifyUser) -> some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    ZStack {
                        Circle().fill(AppTheme.accent.gradient)
                        Text(userInitial(user)).font(.headline).foregroundStyle(.white)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName ?? "Spotify Lite").fontWeight(.semibold).lineLimit(1)
                        Text("Premium").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)

                List(AppDestination.allCases, selection: $environment.selectedDestination) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .font(.body.weight(.medium))
                        .padding(.vertical, 4)
                        .tag(destination)
                }
                .listStyle(.sidebar)

                HStack(spacing: 8) {
                    Circle().fill(receiverColor).frame(width: 8, height: 8)
                    Text(receiverLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
                .background(.quaternary.opacity(0.35))
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch environment.selectedDestination ?? .home {
                    case .home: HomeView(environment: environment, user: user)
                    case .library: LibraryView(environment: environment)
                    case .search: SearchView(environment: environment)
                    case .settings: SettingsView(environment: environment)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                NowPlayingBar(environment: environment)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle(environment.selectedDestination?.title ?? "Spotify Lite")
    }

    private func userInitial(_ user: SpotifyUser) -> String {
        String((user.displayName ?? user.id).prefix(1)).uppercased()
    }

    private var receiverColor: Color {
        switch environment.spotifydState {
        case .running: AppTheme.accent
        case .starting: .orange
        case .crashed: .red
        default: .secondary
        }
    }

    private var receiverLabel: String {
        switch environment.spotifydState {
        case .running: "Receiver running"
        case .starting: "Receiver starting"
        case .notInstalled: "Receiver not installed"
        case .needsAuthentication: "Receiver needs sign-in"
        case .crashed: "Receiver error"
        case .stopped: "Receiver stopped"
        }
    }

    private func bootstrapIfPossible() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        guard premiumConfirmed, !clientID.isEmpty else { return }
        do {
            _ = try await environment.authorizer.validAccessToken()
            let user = try await environment.api.currentUser()
            environment.sessionState = .ready(user)
        } catch {
            environment.sessionState = .needsSetup
        }
    }

    private func observeReceiver() async {
        let installation = await environment.spotifyd.inspectInstallation()
        if !installation.isInstalled { environment.spotifydState = .notInstalled }

        for await event in environment.spotifyd.events {
            guard !Task.isCancelled else { return }
            switch event {
            case .stateChanged(let state): environment.spotifydState = state
            case .connectionInterrupted:
                await environment.playbackCoordinator.receiverConnectionInterrupted()
            case .exited(let status):
                if status == 0 { environment.spotifydState = .stopped }
                else { environment.spotifydState = .crashed(status: status) }
            case .log: break
            }
        }
    }

    private func observePlayback() async {
        for await event in environment.playbackCoordinator.events {
            guard !Task.isCancelled else { return }
            switch event {
            case .stateChanged(let playback):
                if environment.isStartingPlayback, playback == nil { continue }
                environment.playback = playback
            case .receiverChanged(let device):
                if let device, environment.playback != nil {
                    environment.playback?.device = device
                }
            case .commandFailed:
                break
            }
        }
    }
}
