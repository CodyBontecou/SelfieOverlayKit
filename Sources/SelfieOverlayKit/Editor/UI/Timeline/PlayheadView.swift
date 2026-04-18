import CoreMedia
import UIKit

/// Vertical line rendered over the ruler + track rows, positioned by
/// `TimelineView` to match `PlaybackController.currentTime`. The visible
/// stroke is 2pt wide but `point(inside:)` extends the hit target so the
/// user can grab the playhead and drag it to scrub.
///
/// VoiceOver: exposed as an `.adjustable` element so the swipe
/// up / down rotor gestures scrub the playhead in one-second steps. The
/// accessibility value reports the current timecode against the total
/// duration.
final class PlayheadView: UIView {

    /// Horizontal padding on each side of the visible line that still counts
    /// as a hit. Keeps the 2pt stroke looking the same while making it easy
    /// to grab with a fingertip.
    static let touchSlop: CGFloat = 16

    /// Seconds that a single VoiceOver adjustable increment / decrement
    /// moves the playhead. One second matches the smallest ruler tick most
    /// users see.
    static let adjustStepSeconds: Double = 1

    /// Current playhead time, driven by `TimelineView.setPlayhead`. Used to
    /// keep `accessibilityValue` in sync with the displayed position.
    var currentTime: CMTime = .zero {
        didSet { refreshAccessibilityValue() }
    }

    /// Total timeline duration — clamps the VoiceOver scrub range.
    var duration: CMTime = .zero {
        didSet { refreshAccessibilityValue() }
    }

    /// Invoked when VoiceOver triggers an adjustable increment or decrement.
    /// The target is already clamped to `[0, duration]`.
    var onAccessibilityScrub: ((CMTime) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true

        line.backgroundColor = UIColor.systemRed
        line.layer.cornerRadius = 1
        line.layer.masksToBounds = true
        line.isUserInteractionEnabled = false
        addSubview(line)

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "Playhead"
        refreshAccessibilityValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = CGRect(
            x: (bounds.width - 2) / 2,
            y: 0,
            width: 2,
            height: bounds.height)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Self.touchSlop, dy: 0).contains(point)
    }

    override func accessibilityIncrement() {
        scrub(by: Self.adjustStepSeconds)
    }

    override func accessibilityDecrement() {
        scrub(by: -Self.adjustStepSeconds)
    }

    private func scrub(by deltaSeconds: Double) {
        let totalSeconds = duration.seconds.isFinite ? max(0, duration.seconds) : 0
        let next = max(0, min(totalSeconds, currentTime.seconds + deltaSeconds))
        onAccessibilityScrub?(CMTime(seconds: next, preferredTimescale: 600))
    }

    private func refreshAccessibilityValue() {
        accessibilityValue = Self.timeString(for: currentTime, total: duration)
    }

    static func timeString(for time: CMTime, total: CMTime) -> String {
        let current = format(time)
        let totalText = format(total)
        return "\(current) of \(totalText)"
    }

    private static func format(_ time: CMTime) -> String {
        let seconds = max(0, time.seconds.isFinite ? time.seconds : 0)
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        if minutes == 0 {
            return "\(secs) \(secs == 1 ? "second" : "seconds")"
        }
        let m = "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        let s = "\(secs) \(secs == 1 ? "second" : "seconds")"
        return "\(m) \(s)"
    }

    private let line = UIView()
}
