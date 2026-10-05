import SwiftUI

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat = 52
    var cornerRadius: CGFloat = 7
    var symbol = "music.note"

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (url: URL, pixelSize: Int, image: CGImage)?

    var body: some View {
        ZStack {
            if let image = currentImage {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            } else {
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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: "\(url?.absoluteString ?? "")#\(pixelSize)") { await load() }
    }

    private var pixelSize: Int {
        Int((size * displayScale).rounded(.up))
    }

    /// Already-decoded artwork renders on the first frame instead of flashing the placeholder.
    private var currentImage: CGImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url, loaded.pixelSize == pixelSize { return loaded.image }
        return ArtworkCache.shared.cachedImage(for: url, pixelSize: pixelSize)
    }

    private func load() async {
        guard let url, currentImage == nil else { return }
        let pixelSize = pixelSize
        guard let image = await ArtworkCache.shared.image(for: url, pixelSize: pixelSize),
              !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            loaded = (url, pixelSize, image)
        }
    }
}

struct TrackRow: View {
    let track: SpotifyTrack
    var onPlay: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.album?.images.artworkURL(forPointSize: 46), size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(track.artists.displayNames)
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

/// Tracks numbered from 1, each playable on click. `onPlay` receives the zero-based index.
struct NumberedTrackList: View {
    let tracks: [SpotifyTrack]
    let onPlay: (SpotifyTrack, Int) -> Void

    var body: some View {
        List(Array(tracks.enumerated()), id: \.element.id) { index, track in
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
                TrackRow(track: track) { onPlay(track, index) }
            }
        }
        .listStyle(.inset)
    }
}

/// Gradient tile with an SF Symbol, used for mixes generated on device.
struct MixArtwork: View {
    let symbol: String
    let size: CGFloat
    let cornerRadius: CGFloat
    let symbolSize: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(LinearGradient(
                    colors: [AppTheme.accent, .purple, .indigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
