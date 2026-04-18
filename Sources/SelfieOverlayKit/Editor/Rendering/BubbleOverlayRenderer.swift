import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import UIKit

/// Per-frame composite: draws the selfie bubble over a screen frame.
///
/// Extracted from `CameraCompositor` so the same logic can be shared by
/// (a) the editor's live preview compositor (T5 — custom `AVVideoCompositing`)
/// and (b) the export fallback path (T14) without duplicating the Core Image
/// code or the shape / border caches.
///
/// Behavior-preserving: the bubble image, masking, border, opacity, mirror,
/// and positioning exactly match what `CameraCompositor` produced pre-refactor.
public final class BubbleOverlayRenderer {

    public struct State: Equatable {
        /// Bubble frame in screen *points* (top-left origin).
        public var frame: CGRect
        public var shape: BubbleShape
        public var mirror: Bool
        public var opacity: Double
        public var borderWidth: CGFloat
        public var borderHue: Double

        public init(frame: CGRect,
                    shape: BubbleShape,
                    mirror: Bool,
                    opacity: Double,
                    borderWidth: CGFloat,
                    borderHue: Double) {
            self.frame = frame
            self.shape = shape
            self.mirror = mirror
            self.opacity = opacity
            self.borderWidth = borderWidth
            self.borderHue = borderHue
        }
    }

    public init() {}

    // MARK: - Public API

    /// Composite the camera bubble onto `screen` and render the result into
    /// `dest`. When `state` or `camera` is nil, `dest` ends up with just the
    /// screen frame.
    ///
    /// `screenScale` is the points→pixels factor of the bubble frame
    /// (typically `UIScreen.main.scale`); `outputSize` is the destination
    /// pixel size.
    public func render(screen: CVPixelBuffer,
                       camera: CVPixelBuffer?,
                       state: State?,
                       screenScale: CGFloat,
                       outputSize: CGSize,
                       into dest: CVPixelBuffer,
                       context: CIContext) {
        let screenImage = CIImage(cvPixelBuffer: screen)
        var composite = screenImage

        if let state, let camera {
            let cameraImage = CIImage(cvPixelBuffer: camera)
            if let bubble = makeBubbleImage(
                camera: cameraImage,
                state: state,
                screenScale: screenScale,
                outputSize: outputSize) {
                composite = bubble.composited(over: screenImage)
            }
        }

        context.render(
            composite,
            to: dest,
            bounds: CGRect(origin: .zero, size: outputSize),
            colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    // MARK: - Bubble image composition

    private func makeBubbleImage(camera: CIImage,
                                 state: State,
                                 screenScale: CGFloat,
                                 outputSize: CGSize) -> CIImage? {
        let widthPx = (state.frame.width * screenScale).rounded()
        let heightPx = (state.frame.height * screenScale).rounded()
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

        if state.mirror {
            bubble = bubble
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: widthPx, y: 0))
        }

        let bubbleSize = CGSize(width: widthPx, height: heightPx)

        if state.shape != .rect,
           let mask = cachedShapeMask(size: bubbleSize, shape: state.shape) {
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

        if state.opacity < 0.999 {
            bubble = bubble.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(state.opacity))
            ])
        }

        if state.borderWidth > 0,
           let border = cachedBorder(size: bubbleSize,
                                     shape: state.shape,
                                     lineWidthPx: state.borderWidth * screenScale,
                                     hue: state.borderHue) {
            bubble = border.composited(over: bubble)
        }

        let tx = state.frame.origin.x * screenScale
        let ty = outputSize.height - (state.frame.origin.y + state.frame.height) * screenScale
        bubble = bubble.transformed(by: CGAffineTransform(translationX: tx, y: ty))

        return bubble
    }

    // MARK: - Mask / border caches

    // Shape masks and border overlays change only when the bubble resizes or
    // switches shape — cache them to avoid re-rendering every frame.
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

extension BubbleOverlayRenderer.State {
    /// Convenience initializer from a `BubbleTimeline.Snapshot` so callers that
    /// already have a timeline snapshot can feed it straight through.
    init(snapshot: BubbleTimeline.Snapshot) {
        self.init(frame: snapshot.frame,
                  shape: snapshot.shape,
                  mirror: snapshot.mirror,
                  opacity: snapshot.opacity,
                  borderWidth: snapshot.borderWidth,
                  borderHue: snapshot.borderHue)
    }
}
