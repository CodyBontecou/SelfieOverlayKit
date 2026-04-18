import CoreMedia
import Foundation

/// Pure magnetic-snap math shared by the trim (T10) and later split / insert
/// flows. Given a candidate time + a set of neighbor times (playhead,
/// adjacent clip edges, ruler beats), `snap(...)` returns the nearest
/// neighbor if it's within the threshold, otherwise the candidate.
///
/// Threshold is expressed in seconds; callers (e.g. `ClipView`'s edge pan)
/// convert the UI's point threshold by dividing by the current
/// `pixelsPerSecond`.
enum SnapEngine {

    static func snap(
        candidate: CMTime,
        neighbors: [CMTime],
        thresholdSeconds: TimeInterval
    ) -> CMTime {
        guard !neighbors.isEmpty, thresholdSeconds > 0 else { return candidate }
        let candSec = candidate.seconds

        var best: CMTime?
        var bestDelta = thresholdSeconds
        for n in neighbors {
            let delta = abs(n.seconds - candSec)
            if delta <= bestDelta {
                bestDelta = delta
                best = n
            }
        }
        return best ?? candidate
    }

    /// Convert a point-space threshold to a time-space threshold using the
    /// current zoom level.
    static func thresholdSeconds(forPoints points: CGFloat,
                                 pixelsPerSecond: CGFloat) -> TimeInterval {
        guard pixelsPerSecond > 0 else { return 0 }
        return TimeInterval(points / pixelsPerSecond)
    }
}
