import UIKit

/// Small pulsing red dot shown in the bubble while recording is active.
///
/// Lives only in the live UIView hierarchy and never reaches the exported
/// video:
/// - The bubble window sits at `windowLevel = .alert + 1`, which ReplayKit
///   in-app capture skips — so the indicator is not in the screen track.
/// - `BubbleStateLogger` samples only the bubble's frame and appearance
///   settings, not its subviews — so the export compositor has no knowledge
///   of the indicator and won't re-render it.
final class RecordingIndicatorView: UIView {

    private static let pulseAnimationKey = "recording.pulse"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemRed
        layer.shadowColor = UIColor.systemRed.cgColor
        layer.shadowOpacity = 0.6
        layer.shadowRadius = 3
        layer.shadowOffset = .zero
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
    }

    func setActive(_ active: Bool) {
        isHidden = !active
        if active {
            startPulsing()
        } else {
            layer.removeAnimation(forKey: Self.pulseAnimationKey)
        }
    }

    private func startPulsing() {
        guard layer.animation(forKey: Self.pulseAnimationKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: Self.pulseAnimationKey)
    }
}
