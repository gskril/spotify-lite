import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var environment: AppEnvironment
    @AppStorage(SpotifyLitePreferences.clientIDKey) private var clientID = ""
    @AppStorage(SpotifyLitePreferences.premiumConfirmedKey) private var premiumConfirmed = false
    @State private var step = 0
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.03), AppTheme.accent.opacity(0.13)],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 24) {
                HStack(spacing: 7) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(index <= step ? AppTheme.accent : .secondary.opacity(0.25))
                            .frame(width: index == step ? 32 : 9, height: 7)
                    }
                }

                Group {
                    switch step {
                    case 0: premiumStep
                    case 1: developerStep
                    default: connectStep
                    }
                }
                .frame(maxWidth: 560)
                .spotifyCard()
            }
            .padding(44)
        }
        .ignoresSafeArea()
        .onAppear {
            if premiumConfirmed && !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                step = 2
            } else if premiumConfirmed {
                step = 1
            }
        }
    }

    private var premiumStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            onboardingHeader(
                symbol: "music.note.house.fill",
                title: "A lighter way to listen",
                subtitle: "Spotify Lite uses Spotify Connect and a small local receiver to play music on this Mac."
            )
            Label("A Spotify Premium account is required for playback control.", systemImage: "checkmark.seal")
                .foregroundStyle(.secondary)
            Toggle("I have Spotify Premium", isOn: $premiumConfirmed)
                .toggleStyle(.checkbox)
            continueButton(disabled: !premiumConfirmed) { step = 1 }
        }
    }

    private var developerStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingHeader(
                symbol: "key.horizontal.fill",
                title: "Add your developer app",
                subtitle: "Spotify asks personal clients to use a free Development Mode app. Only paste the public client ID—never a client secret."
            )

            Button("Open Spotify Developer Dashboard", systemImage: "arrow.up.right.square") {
                NSWorkspace.shared.open(SpotifyLitePreferences.dashboardURL)
            }
            .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 7) {
                Text("Client ID").font(.caption).foregroundStyle(.secondary)
                TextField("Paste the client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Add this exact Redirect URI in the dashboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(SpotifyLitePreferences.redirectURI)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SpotifyLitePreferences.redirectURI, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Copy redirect URI")
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Back") { step = 0 }
                Spacer()
                continueButton(disabled: clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { step = 2 }
                    .fixedSize()
            }
        }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            onboardingHeader(
                symbol: "person.crop.circle.badge.checkmark",
                title: "Connect Spotify",
                subtitle: "Your browser will open so you can approve access. Spotify Lite stores tokens securely and never sees your password."
            )

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }

            HStack {
                Button("Back") { step = 1 }
                    .disabled(isConnecting)
                Spacer()
                Button {
                    connect()
                } label: {
                    HStack {
                        if isConnecting { ProgressView().controlSize(.small) }
                        Text(isConnecting ? "Waiting for Spotify…" : "Connect Spotify")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .controlSize(.large)
                .disabled(isConnecting)
            }
        }
    }

    private func onboardingHeader(symbol: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 33, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
            Text(title)
                .font(.system(size: 27, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func continueButton(disabled: Bool, action: @escaping () -> Void) -> some View {
        Button("Continue", action: action)
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .controlSize(.large)
            .disabled(disabled)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func connect() {
        isConnecting = true
        errorMessage = nil
        environment.sessionState = .authorizing
        Task {
            do {
                try await environment.authorizer.beginAuthorization()
                let user = try await environment.api.currentUser()
                await MainActor.run {
                    environment.sessionState = .ready(user)
                    isConnecting = false
                }
            } catch {
                await MainActor.run {
                    let message = error.localizedDescription
                    environment.sessionState = .failure(message)
                    errorMessage = message
                    isConnecting = false
                }
            }
        }
    }
}
