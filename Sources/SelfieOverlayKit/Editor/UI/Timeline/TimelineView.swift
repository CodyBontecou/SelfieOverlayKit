import Combine
import CoreMedia
import UIKit

/// Horizontal scrollable timeline: ruler + one row per `Track` + playhead.
/// Content width scales with `pixelsPerSecond`, which the pinch gesture
/// adjusts (clamped to a sensible zoom range).
final class TimelineView: UIView {

    // MARK: - Layout constants

    static let rulerHeight: CGFloat = 22
    static let trackHeight: CGFloat = 40
    static let trackSpacing: CGFloat = 6

    // MARK: - Tunables

    var minPixelsPerSecond: CGFloat = 20
    var maxPixelsPerSecond: CGFloat = 400

    private(set) var pixelsPerSecond: CGFloat = 60 {
        didSet {
            pixelsPerSecond = min(max(pixelsPerSecond, minPixelsPerSecond), maxPixelsPerSecond)
            applyZoom()
        }
    }

    // MARK: - State bindings

    /// The current `Timeline` we're rendering.
    private(set) var timeline: Timeline = Timeline()

    /// The clip ID currently shown with a selection border, if any.
    private(set) var selectedClipID: UUID?

    /// Set by the owner when a clip is tapped so the editor can update
    /// inspector / toolbar state.
    var onClipSelected: ((UUID?) -> Void)?

    /// Invoked when the user taps or drags on the ruler to seek.
    var onSeek: ((CMTime) -> Void)?

    // MARK: - Views

    let scrollView = UIScrollView()
    private let contentView = UIView()
    private let rulerView = TimelineRulerView()
    private let playheadView = PlayheadView()
    private var trackRowViews: [UUID: TrackRowView] = [:]

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        backgroundColor = .systemBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        contentView.addSubview(rulerView)
        contentView.addSubview(playheadView)

        let rulerTap = UITapGestureRecognizer(target: self, action: #selector(handleRulerTap(_:)))
        rulerView.addGestureRecognizer(rulerTap)
        let rulerPan = UIPanGestureRecognizer(target: self, action: #selector(handleRulerPan(_:)))
        rulerView.addGestureRecognizer(rulerPan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - Public API

    func update(timeline: Timeline) {
        self.timeline = timeline
        rulerView.duration = timeline.duration
        rulerView.pixelsPerSecond = pixelsPerSecond
        rebuildTrackRows()
        setNeedsLayout()
    }

    func setPlayhead(_ time: CMTime) {
        let x = CGFloat(max(0, time.seconds)) * pixelsPerSecond
        playheadView.frame = CGRect(
            x: x - 1, y: 0,
            width: 2,
            height: contentView.bounds.height)
    }

    func setSelectedClipID(_ id: UUID?) {
        selectedClipID = id
        for row in trackRowViews.values {
            row.setSelectedClipID(id)
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let contentWidth = max(bounds.width, CGFloat(timeline.duration.seconds) * pixelsPerSecond)
        let contentHeight = Self.rulerHeight +
            CGFloat(timeline.tracks.count) * (Self.trackHeight + Self.trackSpacing)

        scrollView.contentSize = CGSize(width: contentWidth, height: contentHeight)
        contentView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        rulerView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: Self.rulerHeight)
        playheadView.frame.size.height = contentHeight
        playheadView.frame.size.width = 2

        var y = Self.rulerHeight
        for track in timeline.tracks {
            guard let row = trackRowViews[track.id] else { continue }
            row.frame = CGRect(x: 0, y: y, width: contentWidth, height: Self.trackHeight)
            y += Self.trackHeight + Self.trackSpacing
        }

        setPlayhead(CMTime(seconds: Double(playheadView.frame.origin.x + 1) / pixelsPerSecond,
                           preferredTimescale: 600))
    }

    // MARK: - Internals

    private func rebuildTrackRows() {
        let currentIDs = Set(timeline.tracks.map(\.id))
        for (id, row) in trackRowViews where !currentIDs.contains(id) {
            row.removeFromSuperview()
            trackRowViews.removeValue(forKey: id)
        }
        for track in timeline.tracks {
            if let existing = trackRowViews[track.id] {
                existing.update(track: track, pixelsPerSecond: pixelsPerSecond)
            } else {
                let row = TrackRowView(track: track, pixelsPerSecond: pixelsPerSecond)
                row.onClipTap = { [weak self] id in
                    self?.selectedClipID = id
                    self?.setSelectedClipID(id)
                    self?.onClipSelected?(id)
                }
                contentView.insertSubview(row, belowSubview: playheadView)
                trackRowViews[track.id] = row
            }
        }
    }

    private func applyZoom() {
        rulerView.pixelsPerSecond = pixelsPerSecond
        for row in trackRowViews.values {
            row.update(track: row.track, pixelsPerSecond: pixelsPerSecond)
        }
        setNeedsLayout()
    }

    // MARK: - Gestures

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .changed {
            pixelsPerSecond = pixelsPerSecond * gesture.scale
            gesture.scale = 1
        }
    }

    @objc private func handleRulerTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: rulerView)
        seekToRulerPoint(point)
    }

    @objc private func handleRulerPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: rulerView)
        seekToRulerPoint(point)
    }

    private func seekToRulerPoint(_ point: CGPoint) {
        let seconds = max(0, Double(point.x) / Double(pixelsPerSecond))
        let clamped = min(seconds, timeline.duration.seconds)
        onSeek?(CMTime(seconds: clamped, preferredTimescale: 600))
    }
}
