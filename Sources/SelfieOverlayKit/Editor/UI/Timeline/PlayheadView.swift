import UIKit

/// Vertical line rendered over the ruler + track rows, positioned by
/// `TimelineView` to match `PlaybackController.currentTime`. The visible
/// stroke is 2pt wide but `point(inside:)` extends the hit target so the
/// user can grab the playhead and drag it to scrub.
final class PlayheadView: UIView {

    /// Horizontal padding on each side of the visible line that still counts
    /// as a hit. Keeps the 2pt stroke looking the same while making it easy
    /// to grab with a fingertip.
    static let touchSlop: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true

        line.backgroundColor = UIColor.systemRed
        line.layer.cornerRadius = 1
        line.layer.masksToBounds = true
        line.isUserInteractionEnabled = false
        addSubview(line)
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

    private let line = UIView()
}
