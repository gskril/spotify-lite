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
                MixArtwork(symbol: symbol, size: 112, cornerRadius: 14, symbolSize: 40)

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

            NumberedTrackList(tracks: tracks) { track, index in play(track, at: index) }
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
