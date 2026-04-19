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

    /// Per-clip transform projected onto the canvas. Shared by both the
    /// screen and camera layers: the renderer crops the source to `cropRect`
    /// (normalized 0..1), scales by `scale`, and translates by `offset`
    /// (in output pixels, relative to the layer's natural centre).
    public struct LayerTransform: Equatable {
        public var cropRect: CGRect
        public var scale: CGFloat
        public var offset: CGPoint

        public static let identity = LayerTransform(
            cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            scale: 1,
            offset: .zero)

        public init(cropRect: CGRect, scale: CGFloat, offset: CGPoint) {
            self.cropRect = cropRect
            self.scale = scale
            self.offset = offset
        }

        var isIdentity: Bool { self == .identity }
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
    ///
    /// `screenTransform` / `cameraTransform` apply per-layer crop/scale/
    /// translate on top of the default "screen fills canvas, camera fills
    /// its bubble frame" behavior. Identity transforms (the default) keep
    /// the fast path byte-identical to the pre-feature behavior.
    /// `cameraShapeOverride == .fullscreen` forces the camera to cover the
    /// full canvas regardless of `state.frame`.
    public func render(screen: CVPixelBuffer,
                       camera: CVPixelBuffer?,
                       state: State?,
                       screenScale: CGFloat,
                       outputSize: CGSize,
                       screenTransform: LayerTransform = .identity,
                       cameraTransform: LayerTransform = .identity,
                       cameraShapeOverride: CameraLayerShape? = nil,
                       backgroundColor: CIColor = CIColor(red: 0, green: 0, blue: 0),
                       into dest: CVPixelBuffer,
                       context: CIContext) {
        let screenImage = CIImage(cvPixelBuffer: screen)
        let canvasRect = CGRect(origin: .zero, size: outputSize)
        var composite: CIImage

        if screenTransform.isIdentity {
            // Fast path: identity transform keeps the pre-feature code exact
            // (no background fill, no crop filter, no aspect math). Covers
            // every un-edited project so performance and rendered pixels are
            // unchanged for them.
            composite = screenImage
        } else {
            let placedRect = placedRect(natural: canvasRect, transform: screenTransform)
            let contentSize = CGSize(width: placedRect.width, height: placedRect.height)
            let content = aspectFill(source: screenImage,
                                     normalizedCrop: screenTransform.cropRect,
                                     targetSize: contentSize)
            let translated = content.transformed(
                by: CGAffineTransform(translationX: placedRect.origin.x,
                                      y: placedRect.origin.y))
            let background = CIImage(color: backgroundColor).cropped(to: canvasRect)
            composite = translated.composited(over: background)
        }

        if let state, let camera {
            let cameraImage = CIImage(cvPixelBuffer: camera)
            if let bubble = makeBubbleImage(
                camera: cameraImage,
                state: state,
                screenScale: screenScale,
                outputSize: outputSize,
                transform: cameraTransform,
                shapeOverride: cameraShapeOverride) {
                composite = bubble.composited(over: composite)
            }
        }

        context.render(
            composite,
            to: dest,
            bounds: canvasRect,
            colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    // The on-canvas rect a layer lands in after its `LayerTransform` is
    // applied. `natural` is the layer's identity placement rect (full canvas
    // for the screen; bubble-in-pixels for the camera). Y is kept in CIImage
    // orientation (origin bottom-left), so the caller doesn't have to
    // re-flip for the camera. `offset.y` is flipped here to match UI "down =
    // positive" expectations.
    private func placedRect(natural: CGRect, transform: LayerTransform) -> CGRect {
        let w = natural.width * transform.scale
        let h = natural.height * transform.scale
        let x = natural.midX - w / 2 + transform.offset.x
        let y = natural.midY - h / 2 - transform.offset.y
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // Crop the source to `normalizedCrop` (a 0..1 sub-rect), aspect-fill the
    // result into `targetSize`, and return the image positioned at origin.
    // Mirrors the aspect-fill + centre-crop math that `makeBubbleImage`
    // originally did inline for the camera bubble, generalized so it can
    // also drive the screen layer.
    private func aspectFill(source: CIImage,
                            normalizedCrop: CGRect,
                            targetSize: CGSize) -> CIImage {
        let srcExtent = source.extent
        let cropped: CIImage
        if normalizedCrop == CGRect(x: 0, y: 0, width: 1, height: 1) {
            cropped = source
        } else {
            let subRect = CGRect(
                x: srcExtent.origin.x + normalizedCrop.origin.x * srcExtent.width,
                y: srcExtent.origin.y + normalizedCrop.origin.y * srcExtent.height,
                width: normalizedCrop.width * srcExtent.width,
                height: normalizedCrop.height * srcExtent.height)
            cropped = source.cropped(to: subRect)
                .transformed(by: CGAffineTransform(translationX: -subRect.minX,
                                                   y: -subRect.minY))
        }

        let cExtent = cropped.extent
        guard cExtent.width > 0, cExtent.height > 0 else { return cropped }
        let fillScale = max(targetSize.width / cExtent.width,
                            targetSize.height / cExtent.height)
        let scaled = cropped.transformed(
            by: CGAffineTransform(scaleX: fillScale, y: fillScale))
        let sExtent = scaled.extent
        let cropX = sExtent.minX + (sExtent.width - targetSize.width) / 2
        let cropY = sExtent.minY + (sExtent.height - targetSize.height) / 2
        let localRect = CGRect(x: cropX, y: cropY,
                               width: targetSize.width, height: targetSize.height)
        return scaled.cropped(to: localRect)
            .transformed(by: CGAffineTransform(translationX: -localRect.minX,
                                               y: -localRect.minY))
    }

    // MARK: - Bubble image composition

    private func makeBubbleImage(camera: CIImage,
                                 state: State,
                                 screenScale: CGFloat,
                                 outputSize: CGSize,
                                 transform: LayerTransform = .identity,
                                 shapeOverride: CameraLayerShape? = nil) -> CIImage? {
        // The bubble's *natural* on-canvas rect — either the recording-time
        // frame from `state`, or the full canvas when the editor forces
        // fullscreen. Y is in CIImage orientation (origin bottom-left).
        let naturalRect: CGRect
        if shapeOverride == .fullscreen {
            naturalRect = CGRect(origin: .zero, size: outputSize)
        } else {
            let widthPx = (state.frame.width * screenScale).rounded()
            let heightPx = (state.frame.height * screenScale).rounded()
            guard widthPx > 1, heightPx > 1 else { return nil }
            let x = state.frame.origin.x * screenScale
            let y = outputSize.height -
                (state.frame.origin.y + state.frame.height) * screenScale
            naturalRect = CGRect(x: x, y: y, width: widthPx, height: heightPx)
        }

        let camExtent = camera.extent
        guard camExtent.width > 0, camExtent.height > 0 else { return nil }

        // Apply the user's canvasScale + canvasOffset to the natural rect.
        let placedRect = placedRect(natural: naturalRect, transform: transform)
        let bubbleSize = CGSize(width: placedRect.width.rounded(),
                                height: placedRect.height.rounded())
        guard bubbleSize.width > 1, bubbleSize.height > 1 else { return nil }

        var bubble = aspectFill(source: camera,
                                normalizedCrop: transform.cropRect,
                                targetSize: bubbleSize)

        if state.mirror {
            bubble = bubble
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: bubbleSize.width, y: 0))
        }

        let effectiveShape = resolveShape(state: state, override: shapeOverride)

        if effectiveShape != .rect,
           let mask = cachedShapeMask(size: bubbleSize, shape: effectiveShape) {
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
                                     shape: effectiveShape,
                                     lineWidthPx: state.borderWidth * screenScale,
                                     hue: state.borderHue) {
            bubble = border.composited(over: bubble)
        }

        bubble = bubble.transformed(
            by: CGAffineTransform(translationX: placedRect.origin.x,
                                  y: placedRect.origin.y))

        return bubble
    }

    // Pick the shape to draw on the bubble. The editor's `CameraLayerShape`
    // takes precedence; `fullscreen` maps to `.rect` since it's a full-canvas
    // square with no rounding. `nil` falls through to the recording-time
    // `state.shape`.
    private func resolveShape(state: State, override: CameraLayerShape?) -> BubbleShape {
        switch override {
        case .circle: return .circle
        case .roundedRect: return .roundedRect
        case .rect, .fullscreen: return .rect
        case .none: return state.shape
        }
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
