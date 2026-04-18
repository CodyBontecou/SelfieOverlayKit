import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal

/// `AVVideoCompositing` that overlays the selfie bubble onto the screen track
/// using `BubbleOverlayRenderer`. Installed on `AVMutableVideoComposition`
/// via `customVideoCompositorClass` by `CompositionBuilder`.
///
/// Thread model:
/// - `startRequest` is called from an arbitrary queue. Work is hopped onto a
///   single serial `renderQueue`, which serializes access to `renderContext`
///   and the shared `BubbleOverlayRenderer`'s mask / border caches.
/// - `renderContextChanged` can fire mid-playback on seek or composition
///   swap; it also hops to `renderQueue`, so context swaps serialize behind
///   any in-flight request rather than racing the pool the request allocated
///   against.
/// - Source pixel buffers from `request.sourceFrame(byTrackID:)` are used
///   only within the request closure and never retained across requests.
public final class BubbleVideoCompositor: NSObject, AVVideoCompositing {

    public var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
    ]

    public var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
    ]

    private let renderQueue = DispatchQueue(
        label: "SelfieOverlayKit.BubbleVideoCompositor", qos: .userInitiated)
    private var renderContext: AVVideoCompositionRenderContext?

    private let renderer = BubbleOverlayRenderer()
    private let ciContext: CIContext = {
        let device = MTLCreateSystemDefaultDevice()
        return device.map { CIContext(mtlDevice: $0) } ?? CIContext()
    }()

    public override init() {
        super.init()
    }

    // MARK: - AVVideoCompositing

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.async { [weak self] in
            self?.renderContext = newRenderContext
        }
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else {
                request.finish(with: CompositorError.deallocated)
                return
            }
            self.handle(request)
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        // All requests run synchronously on renderQueue with no pending-queue
        // bookkeeping, so there is nothing to cancel.
    }

    // MARK: - Per-request work

    private func handle(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? BubbleCompositionInstruction else {
            request.finish(with: CompositorError.unexpectedInstruction)
            return
        }

        guard let screen = request.sourceFrame(byTrackID: instruction.screenTrackID) else {
            request.finish(with: CompositorError.missingScreenFrame)
            return
        }
        let camera = instruction.cameraTrackID.flatMap {
            request.sourceFrame(byTrackID: $0)
        }

        let state = bubbleState(for: request, instruction: instruction)

        guard let context = renderContext else {
            request.finish(with: CompositorError.missingRenderContext)
            return
        }

        guard let dest = context.newPixelBuffer() else {
            request.finish(with: CompositorError.pixelBufferAllocationFailed)
            return
        }

        let outSize = instruction.outputSize == .zero
            ? CGSize(width: CVPixelBufferGetWidth(dest),
                     height: CVPixelBufferGetHeight(dest))
            : instruction.outputSize

        renderer.render(
            screen: screen,
            camera: camera,
            state: state,
            screenScale: instruction.screenScale,
            outputSize: outSize,
            into: dest,
            context: ciContext)

        request.finish(withComposedVideoFrame: dest)
    }

    private func bubbleState(
        for request: AVAsynchronousVideoCompositionRequest,
        instruction: BubbleCompositionInstruction
    ) -> BubbleOverlayRenderer.State? {
        guard let timeline = instruction.bubbleTimeline else { return nil }
        let sourceTime = instruction.sourceTime(forCompositionTime: request.compositionTime)
        guard let snapshot = timeline.sample(at: CMTimeGetSeconds(sourceTime)) else {
            return nil
        }
        return BubbleOverlayRenderer.State(snapshot: snapshot)
    }

    // MARK: - Errors

    enum CompositorError: Error {
        case deallocated
        case unexpectedInstruction
        case missingScreenFrame
        case missingRenderContext
        case pixelBufferAllocationFailed
    }
}
