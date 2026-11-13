import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var environment: AppEnvironment
    @AppStorage(SpotifyLitePreferences.clientIDKey) private var clientID = ""
    @State private var installation: ReceiverInstallation?
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var showingSignOut = false
    @State private var audioOutput = "System default"
    @State private var soloistAPIKey = ""
    @State private var hasSoloistAPIKey = false
    @State private var isReplacingAPIKey = false
    @State private var isPairing = false
    @State private var pairingTask: Task<Void, Never>?

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
                        Circle().fill(environment.receiverState.indicatorColor).frame(width: 9, height: 9)
                        Text(receiverStatus).fontWeight(.medium)
                        Spacer()
                        if isWorking { ProgressView().controlSize(.small) }
                    }

                    if isBuildExpired {
                        expiredBuildNotice
                    } else if isReceiverSetUp {
                        receiverSummary
                    } else {
                        receiverSetup
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                settingsSection("Playback behavior", symbol: "slider.horizontal.3") {
                    Label("Choosing music plays it on this Mac. Use the device picker to continue somewhere else.", systemImage: "hand.raised")
                        .foregroundStyle(.secondary)
                    Label("Volume controls appear only when the active device reports volume support.", systemImage: "speaker.wave.2")
                        .foregroundStyle(.secondary)
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

    // MARK: Receiver setup

    private var isInstalled: Bool { installation?.isInstalled == true }

    private var isPaired: Bool {
        switch environment.receiverState {
        case .needsAuthentication, .notInstalled: false
        default: true
        }
    }

    private var isReceiverSetUp: Bool { isInstalled && hasSoloistAPIKey && isPaired && !isPairing }

    private var isBuildExpired: Bool {
        environment.receiverState == .crashed(status: SoloistSupervisorConfiguration.expiredBuildExitStatus)
    }

    private var deviceName: String { SoloistSupervisorConfiguration.defaultDeviceName }

    /// Three ordered steps; only the first unfinished one is expanded.
    private var receiverSetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Three one-time steps let this Mac play Spotify audio.")
                .foregroundStyle(.secondary)

            setupStep(1, "Download Spotify Soloist", done: isInstalled, active: !isInstalled,
                      detail: installation?.version) {
                Text("Soloist is Spotify's own background player. Spotify requires you to download it yourself: get the Apple Silicon Mac build, unpack it, and drag the soloist file into the Spotify Lite folder.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Download Soloist", systemImage: "arrow.up.right.square") {
                        NSWorkspace.shared.open(SoloistSupervisorConfiguration.downloadsURL)
                    }
                    Button("Open Folder", systemImage: "folder") { openInstallFolder() }
                    Button("I've Added It", systemImage: "arrow.clockwise") { inspect() }
                }
            }

            setupStep(2, "Add your Soloist API key", done: hasSoloistAPIKey, active: isInstalled && !hasSoloistAPIKey,
                      detail: "Saved in Keychain") {
                Text("Soloist needs a personal key from your Spotify Developer Dashboard. Open the dashboard, choose Spotify Soloist API Key, generate one, and paste it here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                apiKeyField
            }

            setupStep(3, "Pair with your Spotify account", done: false, active: isInstalled && hasSoloistAPIKey,
                      detail: nil) {
                if isPairing {
                    pairingInstructions
                } else {
                    Text("Spotify links the receiver to your account when you pick it once in the Spotify app. Start pairing, then follow the steps that appear.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Start Pairing", systemImage: "link") { startPairing() }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                }
            }
        }
    }

    private var pairingInstructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to choose this Mac in Spotify").fontWeight(.semibold)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open the Spotify app on this Mac, or on your phone on the same Wi-Fi.")
                Text("2. Open its device picker (the speaker icon next to the volume control).")
                HStack(spacing: 4) {
                    Text("3. Choose")
                    Text(deviceName).fontWeight(.semibold).textSelection(.enabled)
                }
            }
            Text("This screen updates by itself a few seconds after you choose it. Not listed? Close and reopen the device picker. A VPN that blocks local network access hides it, so pause the VPN or allow local network access. Pairing stops waiting after five minutes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Cancel") { cancelPairing() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var apiKeyField: some View {
        HStack {
            SecureField("Paste your Soloist API key", text: $soloistAPIKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveSoloistAPIKey() }
            Button("Save") { saveSoloistAPIKey() }
                .disabled(soloistAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Open Dashboard", systemImage: "arrow.up.right.square") {
                NSWorkspace.shared.open(SoloistSupervisorConfiguration.apiKeyDashboardURL)
            }
        }
    }

    private func setupStep<Content: View>(
        _ number: Int,
        _ title: String,
        done: Bool,
        active: Bool,
        detail: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? AppTheme.accent : Color.secondary.opacity(active ? 0.25 : 0.1))
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.bold()).foregroundStyle(active ? .primary : .secondary)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).fontWeight(.semibold).foregroundStyle(done || active ? .primary : .secondary)
                    if done, let detail {
                        Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(minHeight: 24)
                if active { content() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number): \(title)\(done ? ", done" : "")")
    }

    /// Shown once all three setup steps are complete.
    private var receiverSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Spotify Soloist", value: installation?.version ?? "Installed")
            if let expiry = installation?.buildExpiry {
                LabeledContent("Build works until", value: expiry.formatted(date: .abbreviated, time: .omitted))
                if expiry.timeIntervalSinceNow < 14 * 86_400 {
                    HStack {
                        Label("Spotify retires each Soloist build after 90 days. Download the current one and replace the old file soon.", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Download") { NSWorkspace.shared.open(SoloistSupervisorConfiguration.downloadsURL) }
                        Button("Open Folder") { openInstallFolder() }
                    }
                }
            }
            LabeledContent("Appears in Spotify as", value: deviceName)
            LabeledContent("Audio output", value: audioOutput)
            if isReplacingAPIKey {
                VStack(alignment: .leading, spacing: 7) {
                    Text("New Soloist API key").font(.caption).foregroundStyle(.secondary)
                    apiKeyField
                    Button("Keep Current Key") { isReplacingAPIKey = false; soloistAPIKey = "" }
                }
            } else {
                LabeledContent("API key") {
                    HStack {
                        Text("Saved in Keychain").foregroundStyle(.secondary)
                        Button("Replace…") { isReplacingAPIKey = true }
                    }
                }
            }

            HStack {
                receiverAction
                Button("Pair Again", systemImage: "link") { startPairing() }
                    .disabled(isWorking)
                    .help("Link the receiver to your Spotify account again, for example after switching accounts.")
                Spacer()
                Button("Recheck", systemImage: "arrow.clockwise") { inspect() }
            }

            Divider()
            Label(
                "The receiver stays available while Spotify Lite is open and stops when the app quits.",
                systemImage: "bolt.horizontal.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var expiredBuildNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This Soloist build has expired", systemImage: "clock.badge.exclamationmark")
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
            Text("Spotify retires each Soloist build after 90 days. Download the current build, unpack it, and replace the soloist file in the Spotify Lite folder. Your pairing and API key are kept.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Download Soloist", systemImage: "arrow.up.right.square") {
                    NSWorkspace.shared.open(SoloistSupervisorConfiguration.downloadsURL)
                }
                Button("Open Folder", systemImage: "folder") { openInstallFolder() }
                Button("I've Replaced It", systemImage: "arrow.clockwise") { replaceExpiredBuild() }
            }
        }
    }

    private func replaceExpiredBuild() {
        Task {
            await inspectAsync()
            startReceiver()
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
        switch environment.receiverState {
        case .running, .starting:
            Button("Restart", systemImage: "arrow.clockwise") { startReceiver(restart: true) }.disabled(isWorking)
        default:
            Button("Start", systemImage: "play.fill") { startReceiver() }.disabled(installation?.isInstalled != true || isWorking)
        }
    }

    private var receiverStatus: String {
        switch environment.receiverState {
        case .notInstalled: "Not installed"
        case .needsAuthentication: "Setup needed"
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .crashed(SoloistSupervisorConfiguration.expiredBuildExitStatus): "Soloist build expired"
        case .crashed(let status): "Crashed (status \(status))"
        }
    }

    private func inspect() { Task { await inspectAsync() } }

    private func inspectAsync() async {
        isWorking = true
        installation = await environment.receiverManager.inspectInstallation()
        // Walking the CoreAudio device list is too slow to repeat on every redraw.
        audioOutput = ReceiverAudioOutput.statusDescription()
        hasSoloistAPIKey = SoloistAPIKeyStore.load() != nil
        isWorking = false
    }

    private func startPairing() {
        isPairing = true
        statusMessage = nil
        pairingTask = Task {
            do {
                try await environment.receiverManager.authenticate()
                try await environment.receiverManager.startKeepingAlive()
                statusMessage = "Paired. Local playback is ready. Choose something to play."
            } catch is CancellationError {
                statusMessage = nil
            } catch {
                statusMessage = error.localizedDescription
            }
            isPairing = false
            pairingTask = nil
        }
    }

    private func cancelPairing() {
        pairingTask?.cancel()
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

    private func saveSoloistAPIKey() {
        do {
            try SoloistAPIKeyStore.save(soloistAPIKey)
            soloistAPIKey = ""
            hasSoloistAPIKey = true
            let wasReplacing = isReplacingAPIKey
            isReplacingAPIKey = false
            // A running receiver keeps using the key it was launched with.
            statusMessage = wasReplacing ? "API key replaced. Restart the receiver to use it." : nil
            // Refreshes the receiver state, which reported setup as incomplete without a key.
            inspect()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func openInstallFolder() {
        let folder = SoloistSupervisorConfiguration().installDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
