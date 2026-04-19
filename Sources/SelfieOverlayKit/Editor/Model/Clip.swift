import CoreGraphics
import CoreMedia
import Foundation

/// Which recorded asset a clip pulls its samples from.
public enum SourceID: String, Codable, Hashable {
    case screen
    case camera
    /// Microphone audio — recorded as part of the screen `.mov` but
    /// modeled as a first-class source so the editor can detach / mute
    /// it independently of the screen video.
    case mic
}

/// On-canvas shape for a camera clip. Kept separate from `BubbleShape`
/// (the recording-time bubble enum) so `.fullscreen` — which only makes
/// sense in the editor — doesn't leak into the live overlay code paths.
/// `nil` on a clip means "inherit the shape from the recording-time
/// `BubbleTimeline` snapshot".
public enum CameraLayerShape: String, Codable, Hashable {
    case circle
    case roundedRect
    case rect
    case fullscreen
}

/// A single segment on a `Track`. Combines a slice of a source asset
/// (`sourceRange`) with where it plays back on the composed timeline
/// (`timelineRange`), plus per-clip speed and volume.
///
/// `timelineRange.duration` must equal `sourceRange.duration / speed`
/// — helpers enforce this invariant.
public struct Clip: Identifiable, Hashable {

    public let id: UUID
    public var sourceID: SourceID
    public var sourceRange: CMTimeRange
    public var timelineRange: CMTimeRange
    public var speed: Double
    public var volume: Float

    /// On-canvas scale multiplier. 1.0 = fill the layer's natural rect;
    /// >1 zooms in (pixels spill outside the bubble shape / canvas and are
    /// clipped); <1 shrinks and exposes the canvas background color.
    public var canvasScale: CGFloat
    /// Translation in output pixels applied after scaling. Origin is the
    /// layer's natural centre (screen: canvas centre; camera: bubble centre
    /// per `BubbleTimeline.Snapshot.frame`).
    public var canvasOffset: CGPoint
    /// Normalized sub-rect of the source to show. Unit square
    /// `CGRect(x:0, y:0, width:1, height:1)` = full source.
    public var cropRect: CGRect
    /// Camera-clip-only shape override; `nil` preserves the recording-time
    /// bubble shape from `BubbleTimeline`.
    public var cameraShape: CameraLayerShape?

    public init(id: UUID = UUID(),
                sourceID: SourceID,
                sourceRange: CMTimeRange,
                timelineRange: CMTimeRange,
                speed: Double = 1.0,
                volume: Float = 1.0,
                canvasScale: CGFloat = 1.0,
                canvasOffset: CGPoint = .zero,
                cropRect: CGRect = Clip.defaultCropRect,
                cameraShape: CameraLayerShape? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.sourceRange = sourceRange
        self.timelineRange = timelineRange
        self.speed = speed
        self.volume = volume
        self.canvasScale = canvasScale
        self.canvasOffset = canvasOffset
        self.cropRect = cropRect
        self.cameraShape = cameraShape
    }

    public static let defaultCropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
}

public extension Clip {
    /// Build a clip whose timelineRange is derived from `sourceRange` at the
    /// given playback speed and starts at `timelineStart`.
    static func stretched(id: UUID = UUID(),
                          sourceID: SourceID,
                          sourceRange: CMTimeRange,
                          timelineStart: CMTime,
                          speed: Double = 1.0,
                          volume: Float = 1.0,
                          canvasScale: CGFloat = 1.0,
                          canvasOffset: CGPoint = .zero,
                          cropRect: CGRect = Clip.defaultCropRect,
                          cameraShape: CameraLayerShape? = nil) -> Clip {
        precondition(speed > 0, "speed must be positive")
        let raw = CMTimeMultiplyByFloat64(sourceRange.duration, multiplier: 1.0 / speed)
        let timelineDuration = CMTimeConvertScale(raw,
                                                  timescale: sourceRange.duration.timescale,
                                                  method: .default)
        return Clip(id: id,
                    sourceID: sourceID,
                    sourceRange: sourceRange,
                    timelineRange: CMTimeRange(start: timelineStart, duration: timelineDuration),
                    speed: speed,
                    volume: volume,
                    canvasScale: canvasScale,
                    canvasOffset: canvasOffset,
                    cropRect: cropRect,
                    cameraShape: cameraShape)
    }
}
