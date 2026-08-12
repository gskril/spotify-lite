import SwiftUI

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat = 52
    var cornerRadius: CGFloat = 7
    var symbol = "music.note"

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    LinearGradient(
                        colors: [.purple.opacity(0.75), AppTheme.accent.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.34, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct TrackRow: View {
    let track: SpotifyTrack
    var onPlay: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.album?.images.first?.url, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(track.artists.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if track.explicit {
                Text("E")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            }
            Text(track.durationMS.durationText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let onPlay {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.plain)
                .help("Play")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

extension Int {
    var durationText: String {
        let totalSeconds = self / 1_000
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

