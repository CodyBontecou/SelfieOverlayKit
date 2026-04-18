import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import UIKit

/// Generates a horizontal thumbnail strip for a video asset and caches it
/// as a PNG under the project's `cache/` folder. Callers should always
/// call `cachedStrip(at:)` first — if the cache is present, re-opening
/// the project shows thumbnails instantly.
final class ThumbnailStripRenderer {

    static let shared = ThumbnailStripRenderer()

    private let renderQueue = DispatchQueue(
        label: "SelfieOverlayKit.ThumbnailStripRenderer",
        qos: .utility)

    /// Returns a cached thumbnail strip if one is on disk. Non-blocking.
    func cachedStrip(at cacheURL: URL) -> UIImage? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        return UIImage(contentsOfFile: cacheURL.path)
    }

    /// Generate + cache a thumbnail strip for the given asset. Runs off-main.
    /// `completion` fires on the main queue.
    func renderAndCache(
        asset: AVAsset,
        cacheURL: URL,
        count: Int,
        thumbnailSize: CGSize,
        completion: @escaping (UIImage?) -> Void
    ) {
        renderQueue.async {
            let image = Self.renderStrip(asset: asset, count: count, thumbnailSize: thumbnailSize)
            if let image, let data = image.pngData() {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Render `count` evenly-spaced thumbnails from the asset and tile them
    /// horizontally into a single UIImage. Exposed for tests.
    static func renderStrip(asset: AVAsset, count: Int, thumbnailSize: CGSize) -> UIImage? {
        guard count > 0,
              thumbnailSize.width > 0,
              thumbnailSize.height > 0 else { return nil }
        let duration = asset.duration
        guard duration.seconds > 0 else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailSize.width * 2,
                                       height: thumbnailSize.height * 2)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let stepSeconds = duration.seconds / Double(count)
        var frames: [CGImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: Double(i) * stepSeconds, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: t, actualTime: nil) {
                frames.append(cg)
            }
        }
        guard !frames.isEmpty else { return nil }

        let width = thumbnailSize.width * CGFloat(count)
        let height = thumbnailSize.height
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                               format: format)
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var x: CGFloat = 0
            for frame in frames {
                let rect = CGRect(x: x, y: 0, width: thumbnailSize.width, height: thumbnailSize.height)
                ctx.cgContext.draw(frame, in: rect)
                x += thumbnailSize.width
            }
        }
    }
}
