import Foundation
import CoreGraphics
import ImageIO

/// A decoded artwork bitmap. `CGImage` is immutable, so handing one across tasks is safe.
private struct ArtworkBitmap: @unchecked Sendable {
    let image: CGImage
}

/// Downloads Spotify artwork once, decodes it at its displayed pixel size, and keeps the
/// result in memory, so rows that scroll back into view or reappear after navigation render
/// without another request or full-size decode. Spotify image URLs are content-addressed,
/// so the bounded disk cache is reused across launches without revalidation.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let decoded = NSCache<NSString, CGImage>()
    private var inFlight: [String: Task<ArtworkBitmap?, Never>] = [:]
    private let session: URLSession

    private init() {
        decoded.totalCostLimit = 48 * 1024 * 1024

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SpotifyLite/Artwork", isDirectory: true)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 100 * 1024 * 1024, directory: directory)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    func cachedImage(for url: URL, pixelSize: Int) -> CGImage? {
        decoded.object(forKey: Self.key(url, pixelSize) as NSString)
    }

    /// Concurrent requests for the same artwork and size share one download and decode.
    func image(for url: URL, pixelSize: Int) async -> CGImage? {
        let key = Self.key(url, pixelSize)
        if let image = decoded.object(forKey: key as NSString) { return image }
        if let pending = inFlight[key] { return await pending.value?.image }

        let session = session
        let task = Task.detached(priority: .utility) {
            await fetchArtwork(url, pixelSize: pixelSize, session: session)
        }
        inFlight[key] = task
        let bitmap = await task.value
        inFlight[key] = nil
        guard let image = bitmap?.image else { return nil }
        decoded.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    private static func key(_ url: URL, _ pixelSize: Int) -> String {
        "\(url.absoluteString)#\(pixelSize)"
    }
}

/// Downloads and decodes off the main actor.
private func fetchArtwork(_ url: URL, pixelSize: Int, session: URLSession) async -> ArtworkBitmap? {
    guard let result = try? await session.data(from: url),
          let status = (result.1 as? HTTPURLResponse)?.statusCode,
          (200..<300).contains(status),
          let source = CGImageSourceCreateWithData(result.0 as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, pixelSize)
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return ArtworkBitmap(image: image)
}
