import CoreGraphics
import Foundation

/// Sequence of bubble-state snapshots captured during recording. The compositor
/// samples this to know where and how to draw the camera feed onto each frame
/// of the screen recording.
///
/// Kept pure (no UIKit / AVFoundation) so it can be unit-tested without the
/// live camera stack.
struct BubbleTimeline: Codable, Equatable {

    struct Snapshot: Codable, Equatable {
        /// Seconds relative to video start (first screen sample PTS).
        let time: TimeInterval
        /// Bubble frame in screen *points* (top-left origin).
        let frame: CGRect
        let shape: BubbleShape
        let mirror: Bool
        let opacity: Double
        let borderWidth: CGFloat
        let borderHue: Double
    }

    var snapshots: [Snapshot]

    /// Snapshot in effect at `time`: the most recent one whose time ≤ t.
    /// Returns the first snapshot if t precedes all of them, or `nil` if empty.
    func sample(at time: TimeInterval) -> Snapshot? {
        guard let first = snapshots.first else { return nil }
        if time <= first.time { return first }
        var best = first
        for s in snapshots {
            if s.time <= time {
                best = s
            } else {
                break
            }
        }
        return best
    }
}
