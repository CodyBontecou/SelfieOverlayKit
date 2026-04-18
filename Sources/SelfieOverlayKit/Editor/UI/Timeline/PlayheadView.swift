import UIKit

/// Vertical line rendered over the ruler + track rows, positioned by
/// `TimelineView` to match `PlaybackController.currentTime`.
final class PlayheadView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemRed
        layer.cornerRadius = 1
        layer.masksToBounds = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
