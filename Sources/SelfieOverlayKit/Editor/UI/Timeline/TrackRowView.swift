import UIKit

/// One lane in the timeline — renders every `Clip` in a `Track` at its
/// timeline position. Positions are recomputed whenever `track` or
/// `pixelsPerSecond` is assigned.
final class TrackRowView: UIView {

    private(set) var track: Track
    private(set) var pixelsPerSecond: CGFloat

    var onClipTap: ((UUID) -> Void)?

    private var clipViews: [UUID: ClipView] = [:]
    private var selectedClipID: UUID?

    init(track: Track, pixelsPerSecond: CGFloat) {
        self.track = track
        self.pixelsPerSecond = pixelsPerSecond
        super.init(frame: .zero)
        backgroundColor = UIColor.tertiarySystemBackground
        layer.cornerRadius = 6
        layer.masksToBounds = true
        rebuildClipViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func update(track: Track, pixelsPerSecond: CGFloat) {
        self.track = track
        self.pixelsPerSecond = pixelsPerSecond
        rebuildClipViews()
        setNeedsLayout()
    }

    func setSelectedClipID(_ id: UUID?) {
        selectedClipID = id
        for (clipID, view) in clipViews {
            view.isSelected = clipID == id
        }
    }

    private func rebuildClipViews() {
        let currentIDs = Set(track.clips.map(\.id))
        // Remove stale
        for (id, view) in clipViews where !currentIDs.contains(id) {
            view.removeFromSuperview()
            clipViews.removeValue(forKey: id)
        }
        // Add / update
        for clip in track.clips {
            if let existing = clipViews[clip.id] {
                existing.update(clip: clip)
            } else {
                let view = ClipView(clip: clip, kind: track.kind)
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleClipTap(_:)))
                view.addGestureRecognizer(tap)
                addSubview(view)
                clipViews[clip.id] = view
            }
            clipViews[clip.id]?.isSelected = (clip.id == selectedClipID)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        for clip in track.clips {
            guard let view = clipViews[clip.id] else { continue }
            let x = CGFloat(clip.timelineRange.start.seconds) * pixelsPerSecond
            let w = CGFloat(clip.timelineRange.duration.seconds) * pixelsPerSecond
            view.frame = CGRect(x: x, y: 2, width: max(w, 2), height: max(h - 4, 0))
        }
    }

    @objc private func handleClipTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view as? ClipView else { return }
        onClipTap?(view.clipID)
    }
}
