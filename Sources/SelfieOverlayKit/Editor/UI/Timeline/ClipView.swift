import CoreMedia
import UIKit

/// A single clip rectangle on a `TrackRowView`. Carries leading + trailing
/// edge handles whose pan gestures emit `EdgeDragEvent` so the timeline
/// can commit a trim via `Timeline.trimming(clipID:edge:newSourceRange:)`.
/// Uses track-kind color with a selection border.
final class ClipView: UIView {

    enum Edge {
        case leading, trailing
    }

    struct EdgeDragEvent {
        let edge: Edge
        /// Total horizontal translation of the pan recognizer, in points.
        /// Caller converts to `CMTime` via the current `pixelsPerSecond`.
        let translationPoints: CGFloat
        let state: UIGestureRecognizer.State
    }

    /// ~20pt hit zone per spec; visible edge is thinner.
    static let edgeHitWidth: CGFloat = 20

    var onEdgeDrag: ((EdgeDragEvent) -> Void)?

    var clipID: UUID { clip.id }
    private(set) var clip: Clip
    private let kind: Track.Kind
    private let selectionLayer = CALayer()

    /// When true, the owning `TrackRowView` skips automatic frame updates
    /// for this view so the drag handler can set it directly.
    var isDraggingEdge: Bool = false

    private let leadingHandle = UIView()
    private let trailingHandle = UIView()
    private let leadingStripe = CALayer()
    private let trailingStripe = CALayer()

    var isSelected: Bool = false {
        didSet {
            selectionLayer.borderWidth = isSelected ? 2 : 0
            selectionLayer.borderColor = isSelected
                ? UIColor.systemBlue.cgColor
                : UIColor.clear.cgColor
            leadingHandle.isUserInteractionEnabled = isSelected
            trailingHandle.isUserInteractionEnabled = isSelected
            leadingStripe.opacity = isSelected ? 1 : 0
            trailingStripe.opacity = isSelected ? 1 : 0
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

        setupHandle(leadingHandle, stripe: leadingStripe, action: #selector(handleLeadingPan(_:)))
        setupHandle(trailingHandle, stripe: trailingStripe, action: #selector(handleTrailingPan(_:)))
        addSubview(leadingHandle)
        addSubview(trailingHandle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setupHandle(_ handle: UIView, stripe: CALayer, action: Selector) {
        handle.backgroundColor = .clear
        handle.isUserInteractionEnabled = false
        stripe.backgroundColor = UIColor.systemBlue.cgColor
        stripe.cornerRadius = 1
        stripe.opacity = 0
        handle.layer.addSublayer(stripe)
        let pan = UIPanGestureRecognizer(target: self, action: action)
        pan.maximumNumberOfTouches = 1
        handle.addGestureRecognizer(pan)
    }

    func update(clip: Clip) {
        self.clip = clip
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        selectionLayer.frame = bounds
        let hit = Self.edgeHitWidth
        leadingHandle.frame = CGRect(x: 0, y: 0, width: hit, height: bounds.height)
        trailingHandle.frame = CGRect(x: bounds.width - hit, y: 0, width: hit, height: bounds.height)

        let stripeWidth: CGFloat = 3
        let inset: CGFloat = 4
        leadingStripe.frame = CGRect(
            x: (leadingHandle.bounds.width - stripeWidth) / 2,
            y: inset,
            width: stripeWidth,
            height: max(0, leadingHandle.bounds.height - 2 * inset))
        trailingStripe.frame = CGRect(
            x: (trailingHandle.bounds.width - stripeWidth) / 2,
            y: inset,
            width: stripeWidth,
            height: max(0, trailingHandle.bounds.height - 2 * inset))
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // When selected, make edge handles take priority over the body so
        // taps near the edges become drags.
        if isSelected {
            if leadingHandle.frame.contains(point) { return leadingHandle }
            if trailingHandle.frame.contains(point) { return trailingHandle }
        }
        return super.hitTest(point, with: event)
    }

    // MARK: - Pan handlers

    @objc private func handleLeadingPan(_ gesture: UIPanGestureRecognizer) {
        emit(gesture: gesture, edge: .leading)
    }

    @objc private func handleTrailingPan(_ gesture: UIPanGestureRecognizer) {
        emit(gesture: gesture, edge: .trailing)
    }

    private func emit(gesture: UIPanGestureRecognizer, edge: Edge) {
        let translation = gesture.translation(in: self).x
        onEdgeDrag?(.init(edge: edge, translationPoints: translation, state: gesture.state))
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
