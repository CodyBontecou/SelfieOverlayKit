import AVFoundation
import CoreImage
import CoreMedia
import UIKit

/// Reads the raw screen recording and the raw camera recording, composites the
/// selfie bubble on top of each screen frame using the `BubbleTimeline`, and
/// passes any audio track on the screen recording straight through. Writes a
/// single `.mp4` ready for preview/share/save.
///
/// Compositing the camera in post (rather than hoping ReplayKit's in-app
/// capture picks up the overlay window) is what guarantees the selfie actually
/// lands in the exported video.
final class CameraCompositor {

    struct Inputs {
        let screenURL: URL
        let cameraURL: URL
        let bubbleTimeline: BubbleTimeline
        /// Points-to-pixels factor for the bubble frame (e.g., `UIScreen.main.scale`).
        let screenScale: CGFloat
    }

    enum CompositorError: Error {
        case trackMissing
        case readerInitFailed(Error)
        case writerInitFailed(Error)
        case startWritingFailed(Error?)
        case exportFailed(Error?)
    }

    struct Progress {
        let framesProcessed: Int
        let estimatedTotalFrames: Int?
        let elapsedSeconds: TimeInterval
    }

    /// Fires on an arbitrary queue every ~30 frames during compositing so callers
    /// can surface progress (e.g., to the processing HUD).
    var onProgress: ((Progress) -> Void)?

    /// Fires on an arbitrary queue as the compositor transitions between setup
    /// phases. Pairs with `onProgress` so the HUD can show whether we're stuck
    /// in setup vs. stuck between frames.
    var onStatus: ((String) -> Void)?

    private func notify(_ phase: String) {
        DebugLog.log("compositor", phase)
        onStatus?(phase)
    }

    private let ciContext: CIContext = {
        let device = MTLCreateSystemDefaultDevice()
        return device.map { CIContext(mtlDevice: $0) } ?? CIContext()
    }()

    private let workQueue = DispatchQueue(
        label: "SelfieOverlayKit.CameraCompositor", qos: .userInitiated)
    private let videoQueue = DispatchQueue(
        label: "SelfieOverlayKit.CameraCompositor.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(
        label: "SelfieOverlayKit.CameraCompositor.audio", qos: .userInitiated)

    // Shape masks and border overlays change only when the bubble resizes or
    // switches shape, so cache them to avoid re-rendering every frame.
    private struct ShapeKey: Hashable {
        let width: Int
        let height: Int
        let shape: BubbleShape
    }
    private var maskCache: [ShapeKey: CIImage] = [:]

    private struct BorderKey: Hashable {
        let width: Int
        let height: Int
        let shape: BubbleShape
        let lineWidthQuantized: Int
        let hueQuantized: Int
    }
    private var borderCache: [BorderKey: CIImage] = [:]

    func composite(_ inputs: Inputs,
                   completion: @escaping (Result<URL, Error>) -> Void) {
        // Strong `self`: the caller typically holds this compositor only as a
        // local in its closure, so a weak capture lets the instance deallocate
        // before the async work starts and silently drops the composite.
        workQueue.async {
            do {
                let url = try self.perform(inputs)
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Pipeline

    private func perform(_ inputs: Inputs) throws -> URL {
        let startedAt = CACurrentMediaTime()
        notify("Opening recordings")
        let screenAsset = AVURLAsset(url: inputs.screenURL)
        let cameraAsset = AVURLAsset(url: inputs.cameraURL)

        notify("Reading track metadata")
        guard let screenVideoTrack = screenAsset.tracks(withMediaType: .video).first,
              let cameraVideoTrack = cameraAsset.tracks(withMediaType: .video).first else {
            DebugLog.log("compositor", "missing tracks: screen=\(screenAsset.tracks(withMediaType: .video).count) camera=\(cameraAsset.tracks(withMediaType: .video).count)")
            throw CompositorError.trackMissing
        }
        let screenAudioTrack = screenAsset.tracks(withMediaType: .audio).first

        let screenSize = screenVideoTrack.naturalSize
        let outputWidth = Int(screenSize.width.rounded())
        let outputHeight = Int(screenSize.height.rounded())
        let outputSize = CGSize(width: outputWidth, height: outputHeight)

        let screenDuration = CMTimeGetSeconds(screenAsset.duration)
        let screenFPS = Double(screenVideoTrack.nominalFrameRate)
        let cameraDuration = CMTimeGetSeconds(cameraAsset.duration)
        let cameraFPS = Double(cameraVideoTrack.nominalFrameRate)
        let estimatedTotalFrames: Int? = screenFPS > 0
            ? Int((screenDuration * screenFPS).rounded())
            : nil
        DebugLog.log("compositor", 
            "begin: output=\(outputWidth)×\(outputHeight) screen=\(String(format: "%.2f", screenDuration))s@\(String(format: "%.1f", screenFPS))fps camera=\(String(format: "%.2f", cameraDuration))s@\(String(format: "%.1f", cameraFPS))fps hasAudio=\(screenAudioTrack != nil) estFrames=\(estimatedTotalFrames ?? -1)")

        notify("Initializing readers")
        let screenVideoReader: AVAssetReader
        let cameraReader: AVAssetReader
        do {
            screenVideoReader = try AVAssetReader(asset: screenAsset)
            cameraReader = try AVAssetReader(asset: cameraAsset)
        } catch {
            throw CompositorError.readerInitFailed(error)
        }

        let bgra: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let screenVideoOut = AVAssetReaderTrackOutput(
            track: screenVideoTrack, outputSettings: bgra)
        let cameraOut = AVAssetReaderTrackOutput(
            track: cameraVideoTrack, outputSettings: bgra)
        screenVideoReader.add(screenVideoOut)
        cameraReader.add(cameraOut)

        // Audio passthrough: read with nil settings so samples land as-is.
        var audioReader: AVAssetReader?
        var audioOut: AVAssetReaderTrackOutput?
        if let screenAudioTrack {
            let reader = try AVAssetReader(asset: screenAsset)
            let out = AVAssetReaderTrackOutput(track: screenAudioTrack, outputSettings: nil)
            reader.add(out)
            audioReader = reader
            audioOut = out
        }

        notify("Initializing writer")
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("selfieoverlay-final-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        } catch {
            throw CompositorError.writerInitFailed(error)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight
            ])
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOut != nil, let screenAudioTrack {
            // Passthrough audio into an .mp4 container needs a sourceFormatHint,
            // otherwise writer.canAdd silently refuses the input and the export
            // comes out muted.
            let hint = screenAudioTrack.formatDescriptions.first
                .map { $0 as! CMFormatDescription }
            let input = AVAssetWriterInput(
                mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                DebugLog.log("compositor", "writer.canAdd(audio) returned false; export will be silent")
            }
        }

        notify("Starting writer")
        guard writer.startWriting() else {
            DebugLog.log("compositor", "startWriting failed: \(String(describing: writer.error))")
            throw CompositorError.startWritingFailed(writer.error)
        }
        notify("Starting readers")
        guard screenVideoReader.startReading(), cameraReader.startReading() else {
            writer.cancelWriting()
            DebugLog.log("compositor", "startReading failed: screen=\(String(describing: screenVideoReader.error)) camera=\(String(describing: cameraReader.error))")
            throw CompositorError.exportFailed(
                screenVideoReader.error ?? cameraReader.error)
        }
        _ = audioReader?.startReading()
        DebugLog.log("compositor", "readers + writer started")

        notify("Buffering first camera frame")
        // Camera lookahead: hold the most recent camera frame ≤ screen PTS, peeking
        // one ahead to know when to advance.
        var currentCameraFrame: CVPixelBuffer?
        var nextCameraFrame: (buffer: CVPixelBuffer, pts: CMTime)? = nil
        if let first = cameraOut.copyNextSampleBuffer(),
           let buf = CMSampleBufferGetImageBuffer(first) {
            nextCameraFrame = (buf, CMSampleBufferGetPresentationTimeStamp(first))
            DebugLog.log("compositor", "first camera frame pts=\(String(format: "%.3f", CMTimeGetSeconds(nextCameraFrame!.pts)))s")
        } else {
            DebugLog.log("compositor", "no initial camera frame available (readerStatus=\(cameraReader.status.rawValue))")
        }
        notify("Requesting video input")

        var sessionStarted = false
        var firstScreenPTSSeconds: TimeInterval = 0
        var framesProcessed = 0
        var lastLoggedFrame = 0
        var callbackInvocations = 0
        let videoDone = DispatchSemaphore(value: 0)

        videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
            guard let self else { return }
            callbackInvocations += 1
            if callbackInvocations == 1 {
                DebugLog.log("compositor", "video callback fired (isReadyForMoreMediaData=\(videoInput.isReadyForMoreMediaData))")
            }
            while videoInput.isReadyForMoreMediaData {
                guard let screenSample = screenVideoOut.copyNextSampleBuffer() else {
                    let elapsed = CACurrentMediaTime() - startedAt
                    DebugLog.log("compositor", "video reader exhausted after \(framesProcessed) frames in \(String(format: "%.2f", elapsed))s (readerStatus=\(screenVideoReader.status.rawValue) writerStatus=\(writer.status.rawValue))")
                    if let err = screenVideoReader.error {
                        DebugLog.log("compositor", "video reader error: \(err.localizedDescription)")
                    }
                    videoInput.markAsFinished()
                    videoDone.signal()
                    return
                }
                guard let screenBuffer = CMSampleBufferGetImageBuffer(screenSample) else {
                    continue
                }
                let screenPTS = CMSampleBufferGetPresentationTimeStamp(screenSample)

                if !sessionStarted {
                    writer.startSession(atSourceTime: screenPTS)
                    sessionStarted = true
                    firstScreenPTSSeconds = CMTimeGetSeconds(screenPTS)
                    DebugLog.log("compositor", "first frame: pts=\(String(format: "%.3f", firstScreenPTSSeconds))s")
                }

                while let next = nextCameraFrame,
                      CMTimeCompare(next.pts, screenPTS) <= 0 {
                    currentCameraFrame = next.buffer
                    if let s = cameraOut.copyNextSampleBuffer(),
                       let b = CMSampleBufferGetImageBuffer(s) {
                        nextCameraFrame = (b, CMSampleBufferGetPresentationTimeStamp(s))
                    } else {
                        nextCameraFrame = nil
                    }
                }
                let cameraForFrame = currentCameraFrame ?? nextCameraFrame?.buffer

                let timelineTime = CMTimeGetSeconds(screenPTS) - firstScreenPTSSeconds
                let snapshot = inputs.bubbleTimeline.sample(at: timelineTime)

                guard let pool = adaptor.pixelBufferPool else {
                    DebugLog.log("compositor", "pixelBufferPool nil at frame \(framesProcessed)")
                    continue
                }
                var outBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                guard let outBuffer else {
                    DebugLog.log("compositor", "pool gave nil pixel buffer at frame \(framesProcessed)")
                    continue
                }

                self.renderFrame(
                    screenBuffer: screenBuffer,
                    cameraBuffer: cameraForFrame,
                    snapshot: snapshot,
                    screenScale: inputs.screenScale,
                    into: outBuffer,
                    outputSize: outputSize)

                if !adaptor.append(outBuffer, withPresentationTime: screenPTS) {
                    DebugLog.log("compositor", "append failed at frame \(framesProcessed) writerStatus=\(writer.status.rawValue) err=\(String(describing: writer.error))")
                    videoInput.markAsFinished()
                    videoDone.signal()
                    return
                }

                framesProcessed += 1
                // Report the first frame immediately, then every 5 frames — a 1s
                // recording is only ~30 frames so waiting for a wider window would
                // give the user no feedback at all.
                let shouldReport = framesProcessed == 1 ||
                    framesProcessed - lastLoggedFrame >= 5
                if shouldReport {
                    lastLoggedFrame = framesProcessed
                    let elapsed = CACurrentMediaTime() - startedAt
                    let fps = elapsed > 0 ? Double(framesProcessed) / elapsed : 0
                    DebugLog.log("compositor", "progress: \(framesProcessed)/\(estimatedTotalFrames ?? -1) frames @ \(String(format: "%.1f", fps)) fps (elapsed \(String(format: "%.2f", elapsed))s)")
                    self.onProgress?(Progress(
                        framesProcessed: framesProcessed,
                        estimatedTotalFrames: estimatedTotalFrames,
                        elapsedSeconds: elapsed))
                }
            }
        }

        let audioDone = DispatchSemaphore(value: 0)
        if let audioInput, let audioOut {
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard let sample = audioOut.copyNextSampleBuffer() else {
                        DebugLog.log("compositor", "audio reader exhausted")
                        audioInput.markAsFinished()
                        audioDone.signal()
                        return
                    }
                    if !audioInput.append(sample) {
                        DebugLog.log("compositor", "audio append failed: \(String(describing: writer.error))")
                        audioInput.markAsFinished()
                        audioDone.signal()
                        return
                    }
                }
            }
        } else {
            audioDone.signal()
        }

        DebugLog.log("compositor", "waiting on video + audio inputs")
        videoDone.wait()
        audioDone.wait()
        DebugLog.log("compositor", "inputs done, calling finishWriting")

        let finishDone = DispatchSemaphore(value: 0)
        writer.finishWriting { finishDone.signal() }
        finishDone.wait()

        let totalElapsed = CACurrentMediaTime() - startedAt
        DebugLog.log("compositor", "finishWriting returned: status=\(writer.status.rawValue) frames=\(framesProcessed) totalElapsed=\(String(format: "%.2f", totalElapsed))s")

        if writer.status == .completed {
            return outURL
        }
        throw CompositorError.exportFailed(writer.error)
    }

    // MARK: - Frame rendering

    private func renderFrame(screenBuffer: CVPixelBuffer,
                             cameraBuffer: CVPixelBuffer?,
                             snapshot: BubbleTimeline.Snapshot?,
                             screenScale: CGFloat,
                             into outputBuffer: CVPixelBuffer,
                             outputSize: CGSize) {
        let screenImage = CIImage(cvPixelBuffer: screenBuffer)
        var composite = screenImage

        if let snapshot, let cameraBuffer {
            let cameraImage = CIImage(cvPixelBuffer: cameraBuffer)
            if let bubble = makeBubbleImage(
                camera: cameraImage,
                snapshot: snapshot,
                screenScale: screenScale,
                outputSize: outputSize) {
                composite = bubble.composited(over: screenImage)
            }
        }

        ciContext.render(
            composite,
            to: outputBuffer,
            bounds: CGRect(origin: .zero, size: outputSize),
            colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    private func makeBubbleImage(camera: CIImage,
                                 snapshot: BubbleTimeline.Snapshot,
                                 screenScale: CGFloat,
                                 outputSize: CGSize) -> CIImage? {
        let widthPx = (snapshot.frame.width * screenScale).rounded()
        let heightPx = (snapshot.frame.height * screenScale).rounded()
        guard widthPx > 1, heightPx > 1 else { return nil }

        let camExtent = camera.extent
        guard camExtent.width > 0, camExtent.height > 0 else { return nil }

        let fillScale = max(widthPx / camExtent.width, heightPx / camExtent.height)
        var bubble = camera.transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))

        let scaledExtent = bubble.extent
        let cropX = scaledExtent.minX + (scaledExtent.width - widthPx) / 2
        let cropY = scaledExtent.minY + (scaledExtent.height - heightPx) / 2
        let cropRect = CGRect(x: cropX, y: cropY, width: widthPx, height: heightPx)
        bubble = bubble
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX,
                                               y: -cropRect.minY))

        if snapshot.mirror {
            bubble = bubble
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: widthPx, y: 0))
        }

        let bubbleSize = CGSize(width: widthPx, height: heightPx)

        if snapshot.shape != .rect,
           let mask = cachedShapeMask(size: bubbleSize, shape: snapshot.shape) {
            // CIBlendWithMask (luminance) — not CIBlendWithAlphaMask. The mask is
            // drawn as opaque black + opaque white, so its alpha channel is a
            // uniform 1 and CIBlendWithAlphaMask would treat it as "all foreground"
            // and leave the bubble uncropped.
            let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: CGRect(origin: .zero, size: bubbleSize))
            bubble = bubble.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: mask
            ])
        }

        if snapshot.opacity < 0.999 {
            bubble = bubble.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(snapshot.opacity))
            ])
        }

        if snapshot.borderWidth > 0,
           let border = cachedBorder(size: bubbleSize,
                                     shape: snapshot.shape,
                                     lineWidthPx: snapshot.borderWidth * screenScale,
                                     hue: snapshot.borderHue) {
            bubble = border.composited(over: bubble)
        }

        let tx = snapshot.frame.origin.x * screenScale
        let ty = outputSize.height - (snapshot.frame.origin.y + snapshot.frame.height) * screenScale
        bubble = bubble.transformed(by: CGAffineTransform(translationX: tx, y: ty))

        return bubble
    }

    // MARK: - Mask / border caches

    private func cachedShapeMask(size: CGSize, shape: BubbleShape) -> CIImage? {
        let key = ShapeKey(width: Int(size.width), height: Int(size.height), shape: shape)
        if let cached = maskCache[key] { return cached }
        guard let image = renderShapeMask(size: size, shape: shape) else { return nil }
        maskCache[key] = image
        return image
    }

    private func cachedBorder(size: CGSize,
                              shape: BubbleShape,
                              lineWidthPx: CGFloat,
                              hue: Double) -> CIImage? {
        let key = BorderKey(
            width: Int(size.width),
            height: Int(size.height),
            shape: shape,
            lineWidthQuantized: Int(lineWidthPx.rounded()),
            hueQuantized: Int((hue * 360).rounded()))
        if let cached = borderCache[key] { return cached }
        guard let image = renderBorder(size: size,
                                       shape: shape,
                                       lineWidthPx: lineWidthPx,
                                       hue: hue) else { return nil }
        borderCache[key] = image
        return image
    }

    // Masks and borders are built in the bubble's *pixel* coordinate space, so
    // force a 1× renderer — otherwise UIGraphicsImageRenderer multiplies by the
    // main-screen scale and produces a mask 3× the bubble's extent, which leaves
    // CIBlendWithAlphaMask sampling the interior of the shape for every pixel
    // and silently drops the rounded-corner effect from the export.
    private static let pixelRendererFormat: UIGraphicsImageRendererFormat = {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        return f
    }()

    private func renderShapeMask(size: CGSize, shape: BubbleShape) -> CIImage? {
        let renderer = UIGraphicsImageRenderer(size: size, format: Self.pixelRendererFormat)
        let img = renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            let path = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerRadius: cornerRadius(for: shape, size: size))
            path.fill()
        }
        guard let cg = img.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    private func renderBorder(size: CGSize,
                              shape: BubbleShape,
                              lineWidthPx: CGFloat,
                              hue: Double) -> CIImage? {
        let renderer = UIGraphicsImageRenderer(size: size, format: Self.pixelRendererFormat)
        let img = renderer.image { ctx in
            ctx.cgContext.clear(CGRect(origin: .zero, size: size))
            let color = UIColor(hue: CGFloat(hue),
                                saturation: 0.7,
                                brightness: 0.95,
                                alpha: 1.0)
            color.setStroke()
            let inset = lineWidthPx / 2
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            guard rect.width > 0, rect.height > 0 else { return }
            let path = UIBezierPath(
                roundedRect: rect,
                cornerRadius: max(0, cornerRadius(for: shape, size: rect.size)))
            path.lineWidth = lineWidthPx
            path.stroke()
        }
        guard let cg = img.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    private func cornerRadius(for shape: BubbleShape, size: CGSize) -> CGFloat {
        switch shape {
        case .circle: return min(size.width, size.height) / 2
        case .roundedRect: return min(size.width, size.height) * 0.18
        case .rect: return 0
        }
    }
}
