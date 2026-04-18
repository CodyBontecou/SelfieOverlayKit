import UIKit
import QuartzCore

/// Samples the bubble's frame + appearance settings on every CADisplayLink tick
/// during recording. Snapshots are tagged with absolute `CACurrentMediaTime()`
/// values so they can be aligned to video PTS (same host clock) at stop time.
final class BubbleStateLogger {

    private weak var bubble: UIView?
    private weak var settings: SettingsStore?
    private var displayLink: CADisplayLink?

    private struct RawSnapshot {
        let absoluteTime: TimeInterval
        let frame: CGRect
        let shape: BubbleShape
        let mirror: Bool
        let opacity: Double
        let borderWidth: CGFloat
        let borderHue: Double
    }
    private var snapshots: [RawSnapshot] = []

    func start(bubble: UIView, settings: SettingsStore) {
        displayLink?.invalidate()
        displayLink = nil
        self.bubble = bubble
        self.settings = settings
        snapshots.removeAll()

        captureSnapshot()

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stops logging and returns the captured timeline, with times rebased to
    /// `videoStartAbsTime` (the first screen sample PTS in host seconds).
    /// Snapshots from before the video started are clamped to t=0 so the
    /// compositor always has something to draw.
    func stop(videoStartAbsTime: TimeInterval?) -> BubbleTimeline {
        displayLink?.invalidate()
        displayLink = nil

        guard let videoStartAbsTime else {
            snapshots.removeAll()
            return BubbleTimeline(snapshots: [])
        }

        let converted: [BubbleTimeline.Snapshot] = snapshots.map { raw in
            let t = max(0, raw.absoluteTime - videoStartAbsTime)
            return BubbleTimeline.Snapshot(
                time: t,
                frame: raw.frame,
                shape: raw.shape,
                mirror: raw.mirror,
                opacity: raw.opacity,
                borderWidth: raw.borderWidth,
                borderHue: raw.borderHue)
        }
        snapshots.removeAll()
        return BubbleTimeline(snapshots: converted)
    }

    @objc private func tick() {
        captureSnapshot()
    }

    private func captureSnapshot() {
        guard let bubble, let settings else { return }
        // bubble.frame is in its superview's coordinate space — the overlay window's
        // root view, which covers the full screen. So this *is* screen-point space.
        snapshots.append(RawSnapshot(
            absoluteTime: CACurrentMediaTime(),
            frame: bubble.frame,
            shape: settings.shape,
            mirror: settings.mirror,
            opacity: settings.opacity,
            borderWidth: settings.borderWidth,
            borderHue: settings.borderHue))
    }
}
