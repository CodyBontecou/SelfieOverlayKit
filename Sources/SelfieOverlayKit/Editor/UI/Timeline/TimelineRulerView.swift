import CoreMedia
import UIKit

/// Draws tick marks + time labels above the track rows. Adaptive interval:
/// the tick spacing grows as the user zooms out so labels don't overlap.
final class TimelineRulerView: UIView {

    var pixelsPerSecond: CGFloat = 60 {
        didSet { setNeedsDisplay() }
    }

    var duration: CMTime = .zero {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draw(_ rect: CGRect) {
        guard duration.seconds > 0, let ctx = UIGraphicsGetCurrentContext() else { return }

        let totalSeconds = duration.seconds
        let interval = tickInterval(forPixelsPerSecond: pixelsPerSecond)
        let labelFont = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: UIColor.secondaryLabel
        ]

        ctx.setStrokeColor(UIColor.separator.cgColor)
        ctx.setLineWidth(1)

        var second = 0.0
        while second <= totalSeconds + 0.0001 {
            let x = CGFloat(second) * pixelsPerSecond
            ctx.move(to: CGPoint(x: x, y: bounds.height - 8))
            ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            let minutes = Int(second) / 60
            let secs = Int(second) % 60
            let text = String(format: "%d:%02d", minutes, secs) as NSString
            text.draw(at: CGPoint(x: x + 2, y: 2), withAttributes: textAttrs)
            second += interval
        }
        ctx.strokePath()
    }

    /// Adaptive tick interval: 1s when zoomed in, 5/10/30s when zoomed out so
    /// labels stay readable.
    static func tickInterval(forPixelsPerSecond pixelsPerSecond: CGFloat) -> Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60]
        let minLabelSpacing: CGFloat = 40
        for c in candidates {
            if CGFloat(c) * pixelsPerSecond >= minLabelSpacing {
                return c
            }
        }
        return candidates.last ?? 60
    }

    private func tickInterval(forPixelsPerSecond pixelsPerSecond: CGFloat) -> Double {
        Self.tickInterval(forPixelsPerSecond: pixelsPerSecond)
    }
}
