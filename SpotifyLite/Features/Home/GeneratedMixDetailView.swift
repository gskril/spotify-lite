import SwiftUI

struct GeneratedMixDetailView: View {
    @ObservedObject var environment: AppEnvironment

    let title: String
    let subtitle: String
    let symbol: String
    let tracks: [SpotifyTrack]
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(
                            colors: [AppTheme.accent, .purple, .indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Image(systemName: symbol)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 112, height: 112)

                VStack(alignment: .leading, spacing: 8) {
                    Text("MADE FOR THIS MOMENT")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Play", systemImage: "play.fill") { playAll() }
                        .buttonStyle(.borderedProminent)
                        .disabled(tracks.isEmpty || environment.isStartingPlayback)
                }
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(22)

            Divider()

            List(Array(tracks.enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                    TrackRow(track: track) { play(track, at: index) }
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 650)
    }

    private func playAll() {
        guard let first = tracks.first else { return }
        environment.playLocally(.uris(tracks.map(\.uri)), preview: first)
    }

    private func play(_ track: SpotifyTrack, at index: Int) {
        environment.playLocally(.uris(tracks.map(\.uri), offset: index), preview: track)
    }
}

struct GeneratedMixModalLayer: View {
    @ObservedObject var environment: AppEnvironment
    let mix: GeneratedMixPresentation
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Button(action: onDismiss) {
                Color.black.opacity(0.58)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .accessibilityLabel("Close mix")

            GeneratedMixDetailView(
                environment: environment,
                title: mix.title,
                subtitle: mix.subtitle,
                symbol: mix.symbol,
                tracks: mix.tracks,
                onDismiss: onDismiss
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
            .padding(28)
            .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
        .animation(.easeOut(duration: 0.16), value: mix.id)
    }
}
