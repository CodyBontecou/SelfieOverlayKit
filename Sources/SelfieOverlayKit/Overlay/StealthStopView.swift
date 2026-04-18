import UIKit

/// Drawn inside `BubbleView` while stealth recording is active. A pulsing red disc
/// with a white stop-square tells the user "tap to end recording" without exposing
/// the live camera preview. Lives in the overlay window, so ReplayKit's in-app
/// capture never sees it.
final class StealthStopView: UIView {

    private static let pulseAnimationKey = "stealth.stop.pulse"
    private let squareLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemRed
        squareLayer.backgroundColor = UIColor.white.cgColor
        squareLayer.cornerRadius = 2
        layer.addSublayer(squareLayer)
        accessibilityLabel = "Stop recording"
        accessibilityHint = "Tap to stop recording and open the editor."
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        let side = min(bounds.width, bounds.height) * 0.34
        squareLayer.frame = CGRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !isHidden {
            startPulsing()
        } else {
            layer.removeAnimation(forKey: Self.pulseAnimationKey)
        }
    }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                layer.removeAnimation(forKey: Self.pulseAnimationKey)
            } else if window != nil {
                startPulsing()
            }
        }
    }

    private func startPulsing() {
        guard layer.animation(forKey: Self.pulseAnimationKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.55
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: Self.pulseAnimationKey)
    }
}
