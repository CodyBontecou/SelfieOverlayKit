import AVFoundation
import CoreMedia
import Foundation
import UIKit

/// Downsamples an audio track into a packed array of peak floats (0…1) and
/// caches them on disk as little-endian `Float32` values so re-opening a
/// project is instant. `WaveformView` draws the peaks scaled to a clip's
/// currently-visible sourceRange.
final class WaveformRenderer {

    static let shared = WaveformRenderer()

    private let renderQueue = DispatchQueue(
        label: "SelfieOverlayKit.WaveformRenderer",
        qos: .utility)

    /// Default density matches the T9 spec (~200 peaks/s); the UI can
    /// downsample further for smaller widths.
    static let peaksPerSecond: Int = 200

    func cachedPeaks(at cacheURL: URL) -> [Float]? {
        guard FileManager.default.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL) else { return nil }
        return Self.decode(data)
    }

    /// Runs off-main. `completion` fires on main.
    func renderAndCache(
        asset: AVAsset,
        cacheURL: URL,
        peaksPerSecond: Int = WaveformRenderer.peaksPerSecond,
        completion: @escaping ([Float]?) -> Void
    ) {
        renderQueue.async {
            let peaks = try? Self.renderPeaks(asset: asset, peaksPerSecond: peaksPerSecond)
            if let peaks {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? Self.encode(peaks).write(to: cacheURL, options: .atomic)
            }
            DispatchQueue.main.async { completion(peaks) }
        }
    }

    /// Read the audio track as 16-bit LPCM and reduce each window to a peak
    /// amplitude in 0…1. Exposed for tests.
    static func renderPeaks(asset: AVAsset, peaksPerSecond: Int) throws -> [Float] {
        guard let track = asset.tracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.startReading()

        guard let first = track.formatDescriptions.first,
              CFGetTypeID(first as CFTypeRef) == CMFormatDescriptionGetTypeID()
        else { return [] }
        let fmt = first as! CMFormatDescription
        guard CMFormatDescriptionGetMediaType(fmt) == kCMMediaType_Audio,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee
        else { return [] }
        let sampleRate = asbd.mSampleRate
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let samplesPerPeak = max(1, Int(sampleRate / Double(peaksPerSecond)))

        var peaks: [Float] = []
        peaks.reserveCapacity(Int(asset.duration.seconds * Double(peaksPerSecond)))

        var window: Int16 = 0
        var windowCount = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length,
                                        dataPointerOut: &dataPointer)
            guard let raw = dataPointer else { continue }
            let sampleCount = length / MemoryLayout<Int16>.size
            raw.withMemoryRebound(to: Int16.self, capacity: sampleCount) { ptr in
                for i in stride(from: 0, to: sampleCount, by: channels) {
                    let absValue = Int16(clamping: abs(Int(ptr[i])))
                    if absValue > window { window = absValue }
                    windowCount += 1
                    if windowCount >= samplesPerPeak {
                        peaks.append(Float(window) / Float(Int16.max))
                        window = 0
                        windowCount = 0
                    }
                }
            }
        }
        if windowCount > 0 {
            peaks.append(Float(window) / Float(Int16.max))
        }
        return peaks
    }

    private static func encode(_ peaks: [Float]) -> Data {
        var data = Data(capacity: peaks.count * MemoryLayout<Float>.size)
        for v in peaks {
            withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { buffer -> [Float] in
            let floatBuffer = buffer.bindMemory(to: Float.self)
            return Array(floatBuffer.prefix(count))
        }
    }
}

/// Renders cached waveform peaks into the ClipView. The drawing range is
/// the slice of peaks between `sourceRange.start` and `sourceRange.end`
/// so trims reveal / hide cached data rather than regenerating.
final class WaveformView: UIView {

    var peaks: [Float] = [] {
        didSet { setNeedsDisplay() }
    }

    /// Offset + length into `peaks` that should be drawn. Defaults to the
    /// full range.
    var peakRange: Range<Int>? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              !peaks.isEmpty else { return }
        let range = peakRange ?? 0..<peaks.count
        guard !range.isEmpty else { return }

        ctx.setFillColor(UIColor.label.withAlphaComponent(0.6).cgColor)
        let midY = bounds.midY
        let visibleCount = range.count
        let widthPerPeak = bounds.width / CGFloat(visibleCount)
        for (drawIndex, peakIndex) in range.enumerated() {
            let peak = peaks[peakIndex]
            let h = max(1, bounds.height * CGFloat(peak))
            let x = CGFloat(drawIndex) * widthPerPeak
            let r = CGRect(x: x, y: midY - h / 2,
                           width: max(widthPerPeak - 0.5, 0.5),
                           height: h)
            ctx.fill(r)
        }
    }
}
