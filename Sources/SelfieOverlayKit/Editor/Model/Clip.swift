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

    public init(id: UUID = UUID(),
                sourceID: SourceID,
                sourceRange: CMTimeRange,
                timelineRange: CMTimeRange,
                speed: Double = 1.0,
                volume: Float = 1.0) {
        self.id = id
        self.sourceID = sourceID
        self.sourceRange = sourceRange
        self.timelineRange = timelineRange
        self.speed = speed
        self.volume = volume
    }
}

public extension Clip {
    /// Build a clip whose timelineRange is derived from `sourceRange` at the
    /// given playback speed and starts at `timelineStart`.
    static func stretched(id: UUID = UUID(),
                          sourceID: SourceID,
                          sourceRange: CMTimeRange,
                          timelineStart: CMTime,
                          speed: Double = 1.0,
                          volume: Float = 1.0) -> Clip {
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
                    volume: volume)
    }
}
