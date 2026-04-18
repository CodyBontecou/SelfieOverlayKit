import CoreMedia
import UIKit

/// A single clip rectangle on a `TrackRowView`. Body only in T8 — trim
/// handles land in T10. Uses track-kind color with a selection border.
final class ClipView: UIView {

    var clipID: UUID { clip.id }
    private(set) var clip: Clip
    private let kind: Track.Kind
    private let selectionLayer = CALayer()

    var isSelected: Bool = false {
        didSet {
            selectionLayer.borderWidth = isSelected ? 2 : 0
            selectionLayer.borderColor = isSelected
                ? UIColor.systemBlue.cgColor
                : UIColor.clear.cgColor
        }
    }

    init(clip: Clip, kind: Track.Kind) {
        self.clip = clip
        self.kind = kind
        super.init(frame: .zero)
        backgroundColor = Self.color(for: kind)
        layer.cornerRadius = 6
        layer.masksToBounds = true
        selectionLayer.cornerRadius = 6
        layer.addSublayer(selectionLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func update(clip: Clip) {
        self.clip = clip
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        selectionLayer.frame = bounds
    }

    private static func color(for kind: Track.Kind) -> UIColor {
        switch kind {
        case .video:
            return UIColor.systemBlue.withAlphaComponent(0.35)
        case .audio:
            return UIColor.systemGreen.withAlphaComponent(0.35)
        }
    }
}
