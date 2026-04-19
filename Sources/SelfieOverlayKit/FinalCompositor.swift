import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import Foundation

/// Produces `final.mov` — the screen recording with the camera feed baked into
/// its bubble (shape, mirror, opacity sampled per frame from `BubbleTimeline`)
/// and audio muxed in. Written alongside the raw tracks by `RawExporter`.
enum FinalCompositor {

    enum Failure: Error, LocalizedError {
        case loadFailed(String)
        case noVideoTrack(URL)
        case trackInsertFailed(String)
        case exportSessionInitFailed
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .loadFailed(let reason):
                return "Final compose: failed to load source asset (\(reason))"
            case .noVideoTrack(let url):
                return "Final compose: no video track in \(url.lastPathComponent)"
            case .trackInsertFailed(let reason):
                return "Final compose: track insertion failed (\(reason))"
            case .exportSessionInitFailed:
                return "Final compose: AVAssetExportSession init failed"
            case .exportFailed(let reason):
                return "Final compose: export failed (\(reason))"
            }
        }
    }

    static let finalFilename = "final.mov"

    /// Composites the screen and camera tracks into a single `final.mov` with
    /// the bubble baked in and audio muxed from either `audioURL` (preferred
    /// when the mic was demuxed) or the embedded audio in `screenURL`.
    ///
    /// `pointBounds` is the coordinate space the `BubbleTimeline` frames live
    /// in — typically `UIScreen.main.bounds.size`. The compositor scales
    /// bubble rects to the screen video's pixel space using this.
    static func compose(
        screenURL: URL,
        cameraURL: URL,
        audioURL: URL?,
        bubbleTimeline: BubbleTimeline,
        pointBounds: CGSize,
        to outputURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let screenAsset = AVURLAsset(url: screenURL)
        let cameraAsset = AVURLAsset(url: cameraURL)
        let audioAsset = audioURL.map { AVURLAsset(url: $0) }

        let keys = ["tracks", "duration"]
        let group = DispatchGroup()
        var loadError: Error?

        for asset in [screenAsset, cameraAsset, audioAsset].compactMap({ $0 }) {
            group.enter()
            asset.loadValuesAsynchronously(forKeys: keys) {
                var e: NSError?
                for key in keys where asset.statusOfValue(forKey: key, error: &e) != .loaded {
                    if loadError == nil {
                        loadError = Failure.loadFailed(
                            e?.localizedDescription ?? "status for key \(key)")
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
            if let loadError {
                completion(.failure(loadError))
                return
            }
            do {
                try performCompose(
                    screenAsset: screenAsset,
                    cameraAsset: cameraAsset,
                    audioAsset: audioAsset,
                    bubbleTimeline: bubbleTimeline,
                    pointBounds: pointBounds,
                    to: outputURL,
                    completion: completion)
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func performCompose(
        screenAsset: AVURLAsset,
        cameraAsset: AVURLAsset,
        audioAsset: AVURLAsset?,
        bubbleTimeline: BubbleTimeline,
        pointBounds: CGSize,
        to outputURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        guard let screenTrack = screenAsset.tracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack(screenAsset.url)
        }
        guard let cameraTrack = cameraAsset.tracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack(cameraAsset.url)
        }

        // Both .movs are anchored to the same wall-clock moment by
        // `RecordingController`; either may run a hair longer. Use the shorter
        // of the two so neither track is asked to supply frames past its end.
        let duration = CMTimeMinimum(screenAsset.duration, cameraAsset.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)

        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()

        let screenTrackID: CMPersistentTrackID = 1
        let cameraTrackID: CMPersistentTrackID = 2

        guard let compScreen = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: screenTrackID),
              let compCamera = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: cameraTrackID) else {
            throw Failure.trackInsertFailed("could not add video tracks to composition")
        }

        do {
            try compScreen.insertTimeRange(timeRange, of: screenTrack, at: .zero)
            try compCamera.insertTimeRange(timeRange, of: cameraTrack, at: .zero)
        } catch {
            throw Failure.trackInsertFailed(error.localizedDescription)
        }
        compScreen.preferredTransform = screenTrack.preferredTransform
        compCamera.preferredTransform = cameraTrack.preferredTransform

        // Audio: prefer the standalone audio.m4a; otherwise fall back to the
        // audio embedded in screen.mov. Silent when neither has any.
        if let audioAsset, let audioTrack = audioAsset.tracks(withMediaType: .audio).first {
            if let compAudio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let audioRange = CMTimeRange(
                    start: .zero,
                    duration: CMTimeMinimum(duration, audioAsset.duration))
                try? compAudio.insertTimeRange(audioRange, of: audioTrack, at: .zero)
            }
        } else if let screenAudio = screenAsset.tracks(withMediaType: .audio).first {
            if let compAudio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? compAudio.insertTimeRange(timeRange, of: screenAudio, at: .zero)
            }
        }

        // Render at the screen track's display-oriented size.
        let screenNatural = screenTrack.naturalSize.applying(screenTrack.preferredTransform)
        let renderSize = CGSize(width: abs(screenNatural.width), height: abs(screenNatural.height))
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = BubbleOverlayInstruction(
            timeRange: timeRange,
            screenTrackID: compScreen.trackID,
            cameraTrackID: compCamera.trackID,
            timeline: bubbleTimeline,
            pointBounds: pointBounds,
            cameraPreferredTransform: cameraTrack.preferredTransform,
            screenPreferredTransform: screenTrack.preferredTransform,
            renderSize: renderSize)
        videoComposition.instructions = [instruction]
        videoComposition.customVideoCompositorClass = BubbleOverlayCompositor.self

        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportSessionInitFailed
        }
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = false

        session.exportAsynchronously {
            switch session.status {
            case .completed:
                completion(.success(()))
            case .cancelled:
                completion(.failure(Failure.exportFailed("cancelled")))
            case .failed:
                completion(.failure(Failure.exportFailed(
                    session.error?.localizedDescription ?? "unknown")))
            default:
                completion(.failure(Failure.exportFailed(
                    "unexpected status \(session.status.rawValue)")))
            }
        }
    }
}

// MARK: - Custom compositor

final class BubbleOverlayInstruction: NSObject, AVVideoCompositionInstructionProtocol {

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID
    let timeline: BubbleTimeline
    let pointBounds: CGSize
    let cameraPreferredTransform: CGAffineTransform
    let screenPreferredTransform: CGAffineTransform
    let renderSize: CGSize

    init(timeRange: CMTimeRange,
         screenTrackID: CMPersistentTrackID,
         cameraTrackID: CMPersistentTrackID,
         timeline: BubbleTimeline,
         pointBounds: CGSize,
         cameraPreferredTransform: CGAffineTransform,
         screenPreferredTransform: CGAffineTransform,
         renderSize: CGSize) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.timeline = timeline
        self.pointBounds = pointBounds
        self.cameraPreferredTransform = cameraPreferredTransform
        self.screenPreferredTransform = screenPreferredTransform
        self.renderSize = renderSize
        self.requiredSourceTrackIDs = [
            NSNumber(value: screenTrackID),
            NSNumber(value: cameraTrackID)
        ]
        super.init()
    }
}

final class BubbleOverlayCompositor: NSObject, AVVideoCompositing {

    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    private let renderQueue = DispatchQueue(label: "SelfieOverlayKit.FinalCompositor.render")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync { self.renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async {
            autoreleasepool {
                self.fulfill(request)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private func fulfill(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? BubbleOverlayInstruction,
              let outputBuffer = renderContext?.newPixelBuffer() else {
            request.finish(with: FinalCompositor.Failure.exportFailed("no render context"))
            return
        }

        let renderSize = instruction.renderSize

        let screenImage = request
            .sourceFrame(byTrackID: instruction.screenTrackID)
            .map { CIImage(cvPixelBuffer: $0) }
            .map { orient($0, preferredTransform: instruction.screenPreferredTransform) }
            ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize))

        var output = screenImage

        if let cameraBuffer = request.sourceFrame(byTrackID: instruction.cameraTrackID),
           let snapshot = instruction.timeline.sample(at: CMTimeGetSeconds(request.compositionTime)) {
            let camera = CIImage(cvPixelBuffer: cameraBuffer)
            let oriented = orient(camera,
                                  preferredTransform: instruction.cameraPreferredTransform)
            if let overlay = makeBubbleOverlay(
                camera: oriented,
                snapshot: snapshot,
                pointBounds: instruction.pointBounds,
                renderSize: renderSize) {
                output = overlay.composited(over: output)
            }
        }

        output = output.cropped(to: CGRect(origin: .zero, size: renderSize))
        ciContext.render(output, to: outputBuffer)
        request.finish(withComposedVideoFrame: outputBuffer)
    }

    /// Bakes `preferredTransform` into the image and places it at origin (0,0).
    private func orient(_ image: CIImage,
                        preferredTransform: CGAffineTransform) -> CIImage {
        let transformed = image.transformed(by: preferredTransform)
        let origin = transformed.extent.origin
        return transformed.transformed(by: CGAffineTransform(
            translationX: -origin.x, y: -origin.y))
    }

    private func makeBubbleOverlay(camera: CIImage,
                                   snapshot: BubbleTimeline.Snapshot,
                                   pointBounds: CGSize,
                                   renderSize: CGSize) -> CIImage? {
        guard pointBounds.width > 0, pointBounds.height > 0 else { return nil }
        let bubbleFrame = snapshot.frame
        guard bubbleFrame.width > 0, bubbleFrame.height > 0 else { return nil }

        let scaleX = renderSize.width / pointBounds.width
        let scaleY = renderSize.height / pointBounds.height

        // Convert bubble rect from UIKit (top-left) to CoreImage (bottom-left) px.
        let pxWidth = bubbleFrame.width * scaleX
        let pxHeight = bubbleFrame.height * scaleY
        let pxX = bubbleFrame.origin.x * scaleX
        let pxY = renderSize.height - bubbleFrame.origin.y * scaleY - pxHeight
        let pxRect = CGRect(x: pxX, y: pxY, width: pxWidth, height: pxHeight)

        var cam = camera
        if snapshot.mirror {
            cam = cam
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: cam.extent.width, y: 0))
        }

        // Aspect-fill into pxRect, matching the live bubble's preview layer.
        let camSize = cam.extent.size
        guard camSize.width > 0, camSize.height > 0 else { return nil }
        let fillScale = max(pxRect.width / camSize.width, pxRect.height / camSize.height)
        var scaled = cam.transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
        // Center the scaled camera over pxRect, then crop to pxRect.
        let dx = pxRect.midX - scaled.extent.midX
        let dy = pxRect.midY - scaled.extent.midY
        scaled = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let filled = scaled.cropped(to: pxRect)

        // Rounded-rect alpha mask sized to pxRect. Using CIRoundedRectangleGenerator
        // (not a UIKit-drawn mask) — prior experiments showed a UIGraphics mask
        // sampled clean but blended all-zero through CIBlendWithAlphaMask.
        let cornerRadius: CGFloat
        switch snapshot.shape {
        case .circle:
            cornerRadius = min(pxRect.width, pxRect.height) / 2
        case .roundedRect:
            cornerRadius = pxRect.width * 0.18
        case .rect:
            cornerRadius = 0
        }

        let maskGen = CIFilter.roundedRectangleGenerator()
        maskGen.extent = pxRect
        maskGen.radius = Float(cornerRadius)
        maskGen.color = CIColor.white
        guard let mask = maskGen.outputImage else { return nil }

        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = filled
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask
        guard var masked = blend.outputImage else { return nil }

        if snapshot.opacity < 1.0 {
            let alpha = CIFilter.colorMatrix()
            alpha.inputImage = masked
            alpha.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(snapshot.opacity))
            if let dimmed = alpha.outputImage {
                masked = dimmed
            }
        }

        return masked.cropped(to: pxRect)
    }
}

