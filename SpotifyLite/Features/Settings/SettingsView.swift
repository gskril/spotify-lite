import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var environment: AppEnvironment
    @AppStorage(SpotifyLitePreferences.clientIDKey) private var clientID = ""
    @State private var installation: SpotifydInstallation?
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var showingSignOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                settingsSection("Spotify account", symbol: "person.crop.circle") {
                    if case .ready(let user) = environment.sessionState {
                        LabeledContent("Signed in as", value: user.displayName ?? user.id)
                        LabeledContent("Playback requirement", value: "Premium confirmed")
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Developer client ID").font(.caption).foregroundStyle(.secondary)
                        SecureField("Client ID", text: $clientID)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Button("Developer Dashboard", systemImage: "arrow.up.right.square") {
                            NSWorkspace.shared.open(SpotifyLitePreferences.dashboardURL)
                        }
                        Spacer()
                        Button("Sign Out", role: .destructive) { showingSignOut = true }
                    }
                }

                settingsSection("Local receiver", symbol: "hifispeaker.2") {
                    HStack {
                        Circle().fill(environment.spotifydState.indicatorColor).frame(width: 9, height: 9)
                        Text(receiverStatus).fontWeight(.medium)
                        Spacer()
                        if isWorking { ProgressView().controlSize(.small) }
                    }

                    if let installation, installation.isInstalled {
                        LabeledContent("spotifyd", value: installation.version ?? "Installed")
                        LabeledContent("Audio output", value: SpotifydAudioOutput.statusDescription())
                        if let path = installation.executableURL?.path {
                            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Install spotifyd with Homebrew, then recheck. Spotify Lite does not bundle or install it automatically.")
                                .foregroundStyle(.secondary)
                            HStack {
                                Text("brew install spotifyd")
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                                Button("Copy", systemImage: "doc.on.doc") { copy("brew install spotifyd") }
                                    .labelStyle(.iconOnly)
                            }
                            .padding(10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    HStack {
                        Button("Recheck", systemImage: "arrow.clockwise") { inspect() }
                        Button("Authenticate", systemImage: "key") { authenticate() }
                            .disabled(installation?.isInstalled != true || isWorking)
                        Spacer()
                        receiverAction
                    }

                    Divider()
                    Label(
                        "The receiver stays available while Spotify Lite is open and stops when the app quits.",
                        systemImage: "bolt.horizontal.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                settingsSection("Playback behavior", symbol: "slider.horizontal.3") {
                    Label("Choosing music plays it on this Mac. Use the device picker to continue somewhere else.", systemImage: "hand.raised")
                        .foregroundStyle(.secondary)
                    Label("Volume controls appear only when the active device reports volume support.", systemImage: "speaker.wave.2")
                        .foregroundStyle(.secondary)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: 680)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .task { await inspectAsync() }
        .confirmationDialog("Sign out of Spotify?", isPresented: $showingSignOut) {
            Button("Sign Out", role: .destructive) { signOut() }
        } message: {
            Text("You can reconnect at any time. Receiver credentials are managed separately.")
        }
    }

    private func settingsSection<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.title3.bold())
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .spotifyCard()
    }

    @ViewBuilder private var receiverAction: some View {
        switch environment.spotifydState {
        case .running, .starting:
            Button("Restart", systemImage: "arrow.clockwise") { startReceiver(restart: true) }.disabled(isWorking)
        default:
            Button("Start", systemImage: "play.fill") { startReceiver() }.disabled(installation?.isInstalled != true || isWorking)
        }
    }

    private var receiverStatus: String {
        switch environment.spotifydState {
        case .notInstalled: "Not installed"
        case .needsAuthentication: "Authentication needed"
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .crashed(let status): "Crashed (status \(status))"
        }
    }

    private func inspect() { Task { await inspectAsync() } }

    private func inspectAsync() async {
        isWorking = true
        installation = await environment.spotifyd.inspectInstallation()
        isWorking = false
    }

    private func authenticate() {
        isWorking = true
        statusMessage = "Complete receiver authentication in the browser window opened by spotifyd."
        Task {
            do {
                try await environment.spotifyd.authenticate()
                try await environment.spotifyd.startKeepingAlive()
                await MainActor.run {
                    statusMessage = "Receiver authentication completed and the receiver is running."
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                    isWorking = false
                }
            }
        }
    }

    private func startReceiver(restart: Bool = false) {
        isWorking = true
        Task {
            do {
                try await environment.startReceiver(restart: restart)
                if restart { statusMessage = "Receiver restarted." }
            } catch {
                statusMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func signOut() {
        Task {
            try? await environment.authorizer.signOut()
            await MainActor.run {
                environment.clearRememberedPlayback()
                environment.sessionState = .needsSetup
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
