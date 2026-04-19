import AVFoundation
import CoreImage
import CoreMedia
import Foundation

/// Instruction consumed by `BubbleVideoCompositor` for a single screen-track
/// segment. Carries the track IDs to pull source frames from, the bubble
/// timeline slice valid for this segment, and the `sourceStart` + `speed`
/// needed to map composition time back to the recorded source time so the
/// bubble snapshot always lines up with the visible frame.
public final class BubbleCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {

    public let timeRange: CMTimeRange
    public let enablePostProcessing: Bool = false
    public let containsTweening: Bool
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let bubbleTimeline: BubbleTimeline?
    let sourceStart: CMTime
    let speed: Double
    let screenScale: CGFloat
    let outputSize: CGSize
    let screenTransform: BubbleOverlayRenderer.LayerTransform
    let cameraTransform: BubbleOverlayRenderer.LayerTransform
    let cameraShapeOverride: CameraLayerShape?
    let backgroundColor: CIColor
    /// Clip IDs this instruction was built from. Carried so the compositor
    /// can look up on-canvas gesture overrides in `PreviewOverrideStore`
    /// keyed by clip and prefer them over the baked transforms.
    let screenClipID: UUID?
    let cameraClipID: UUID?
    let overrideStore: PreviewOverrideStore?

    init(timeRange: CMTimeRange,
         screenTrackID: CMPersistentTrackID,
         cameraTrackID: CMPersistentTrackID?,
         bubbleTimeline: BubbleTimeline?,
         sourceStart: CMTime,
         speed: Double,
         screenScale: CGFloat,
         outputSize: CGSize,
         screenTransform: BubbleOverlayRenderer.LayerTransform = .identity,
         cameraTransform: BubbleOverlayRenderer.LayerTransform = .identity,
         cameraShapeOverride: CameraLayerShape? = nil,
         backgroundColor: CIColor = CIColor(red: 0, green: 0, blue: 0),
         screenClipID: UUID? = nil,
         cameraClipID: UUID? = nil,
         overrideStore: PreviewOverrideStore? = nil) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.bubbleTimeline = bubbleTimeline
        self.sourceStart = sourceStart
        self.speed = speed
        self.screenScale = screenScale
        self.outputSize = outputSize
        self.screenTransform = screenTransform
        self.cameraTransform = cameraTransform
        self.cameraShapeOverride = cameraShapeOverride
        self.backgroundColor = backgroundColor
        self.screenClipID = screenClipID
        self.cameraClipID = cameraClipID
        self.overrideStore = overrideStore
        self.containsTweening = bubbleTimeline.map { !$0.snapshots.isEmpty } ?? false

        var trackIDs: [NSValue] = [NSNumber(value: screenTrackID)]
        if let cameraTrackID {
            trackIDs.append(NSNumber(value: cameraTrackID))
        }
        self.requiredSourceTrackIDs = trackIDs

        super.init()
    }

    /// Map a composition time inside this instruction's `timeRange` back to
    /// the source asset's recording time — what the user saw when the bubble
    /// state at that moment was captured.
    func sourceTime(forCompositionTime t: CMTime) -> CMTime {
        let localSeconds = CMTimeGetSeconds(CMTimeSubtract(t, timeRange.start))
        return CMTimeAdd(
            sourceStart,
            CMTimeMakeWithSeconds(localSeconds * speed, preferredTimescale: 600))
    }
}
