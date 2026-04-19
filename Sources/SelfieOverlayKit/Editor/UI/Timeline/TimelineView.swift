import Combine
import CoreMedia
import UIKit

/// Horizontal scrollable timeline: ruler + one row per `Track` + playhead.
/// Content width scales with `pixelsPerSecond`, which the pinch gesture
/// adjusts (clamped to a sensible zoom range).
final class TimelineView: UIView {

    // MARK: - Layout constants

    static let rulerHeight: CGFloat = 22
    /// Minimum track lane height. Used as a floor; tracks expand beyond this
    /// when there's vertical space available in the timeline container.
    static let minTrackHeight: CGFloat = 44
    /// Upper bound so a single-track timeline doesn't blow up into a giant
    /// lane on tall screens. Two- or three-track layouts will usually hit
    /// this ceiling before they saturate a Pro Max display.
    static let maxTrackHeight: CGFloat = 120
    static let trackSpacing: CGFloat = 6

    // MARK: - Tunables

    var minPixelsPerSecond: CGFloat = 20
    // 1600 px/s ≈ 53 px per frame at 30 fps — enough to land a razor cut
    // on a single-frame "um" onset in an audio clip. Raised from the
    // original 400 so timeline magnification can be used for precision
    // editing, not just coarse trimming.
    var maxPixelsPerSecond: CGFloat = 1600

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

    /// Invoked on trim edge drag events. The editor consumes these to drive
    /// `Timeline.trimming(clipID:edge:newSourceRange:)`.
    var onClipEdgeDrag: ((UUID, ClipView.EdgeDragEvent) -> Void)?

    var trackRowView: ((UUID) -> TrackRowView?) {
        return { [weak self] trackID in self?.trackRowViews[trackID] }
    }

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

        rulerView.isAccessibilityElement = true
        rulerView.accessibilityLabel = "Timeline ruler"
        rulerView.accessibilityTraits = .header

        playheadView.onAccessibilityScrub = { [weak self] time in
            self?.onSeek?(time)
        }

        // Tap on bare track-area background deselects the current clip. Per-
        // clip taps still fire their own gesture recognizers attached to the
        // ClipViews and take precedence because they're hit-tested first.
        let deselectTap = UITapGestureRecognizer(
            target: self, action: #selector(handleBackgroundTap(_:)))
        deselectTap.cancelsTouchesInView = false
        contentView.addGestureRecognizer(deselectTap)

        let rulerTap = UITapGestureRecognizer(target: self, action: #selector(handleRulerTap(_:)))
        rulerView.addGestureRecognizer(rulerTap)
        let rulerPan = UIPanGestureRecognizer(target: self, action: #selector(handleRulerPan(_:)))
        rulerView.addGestureRecognizer(rulerPan)

        let playheadPan = UIPanGestureRecognizer(
            target: self, action: #selector(handlePlayheadPan(_:)))
        playheadView.addGestureRecognizer(playheadPan)

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
        playheadView.duration = timeline.duration
        rebuildTrackRows()
        setNeedsLayout()
    }

    func setPlayhead(_ time: CMTime) {
        let x = CGFloat(max(0, time.seconds)) * pixelsPerSecond
        playheadView.frame = CGRect(
            x: x - 1, y: 0,
            width: 2,
            height: contentView.bounds.height)
        playheadView.currentTime = time
    }

    func setSelectedClipID(_ id: UUID?) {
        selectedClipID = id
        for row in trackRowViews.values {
            row.setSelectedClipID(id)
        }
    }

    /// Zoom the timeline so the currently selected clip fills the scroll
    /// viewport minus `padding` (0..1 fraction) on each side, and scroll
    /// horizontally so the clip is centred. No-op when nothing is selected.
    /// Used by the "zoom to clip" toolbar button so the user can land razor
    /// cuts without dragging the pinch gesture all the way to the ceiling.
    func zoomToSelection(padding: CGFloat = 0.15) {
        guard let id = selectedClipID else { return }
        guard let loc = locate(clipID: id) else { return }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        let duration = clip.timelineRange.duration.seconds
        guard duration > 0, scrollView.bounds.width > 0 else { return }

        let usable = scrollView.bounds.width * (1 - 2 * padding)
        let target = min(max(usable / CGFloat(duration), minPixelsPerSecond),
                         maxPixelsPerSecond)
        pixelsPerSecond = target

        layoutIfNeeded()
        let clipStart = CGFloat(clip.timelineRange.start.seconds) * pixelsPerSecond
        let clipEnd = CGFloat(clip.timelineRange.end.seconds) * pixelsPerSecond
        let centre = (clipStart + clipEnd) / 2
        let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let newOffsetX = min(max(0, centre - scrollView.bounds.width / 2), maxOffset)
        scrollView.setContentOffset(CGPoint(x: newOffsetX, y: 0), animated: true)
    }

    private func locate(clipID: UUID) -> (trackIndex: Int, clipIndex: Int)? {
        for (ti, track) in timeline.tracks.enumerated() {
            if let ci = track.clips.firstIndex(where: { $0.id == clipID }) {
                return (ti, ci)
            }
        }
        return nil
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let contentWidth = max(bounds.width, CGFloat(timeline.duration.seconds) * pixelsPerSecond)
        let trackH = computedTrackHeight()
        let trackCount = CGFloat(max(1, timeline.tracks.count))
        let spacingTotal = CGFloat(max(0, timeline.tracks.count - 1)) * Self.trackSpacing
        let contentHeight = Self.rulerHeight + trackCount * trackH + spacingTotal

        scrollView.contentSize = CGSize(width: contentWidth, height: contentHeight)
        contentView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        rulerView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: Self.rulerHeight)
        playheadView.frame.size.height = contentHeight
        playheadView.frame.size.width = 2

        var y = Self.rulerHeight
        for track in timeline.tracks {
            guard let row = trackRowViews[track.id] else { continue }
            row.frame = CGRect(x: 0, y: y, width: contentWidth, height: trackH)
            y += trackH + Self.trackSpacing
        }

        setPlayhead(CMTime(seconds: Double(playheadView.frame.origin.x + 1) / pixelsPerSecond,
                           preferredTimescale: 600))
    }

    /// Track lanes grow to fill the timeline container's height, clamped to
    /// `[minTrackHeight, maxTrackHeight]`. Keeps thumbnails / waveforms
    /// legible on tall screens without leaving dead whitespace.
    private func computedTrackHeight() -> CGFloat {
        let count = max(1, timeline.tracks.count)
        let spacing = CGFloat(max(0, count - 1)) * Self.trackSpacing
        let available = bounds.height - Self.rulerHeight - spacing
        let fitted = available / CGFloat(count)
        return min(Self.maxTrackHeight, max(Self.minTrackHeight, fitted))
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
                row.onClipEdgeDrag = { [weak self] clipID, event in
                    self?.onClipEdgeDrag?(clipID, event)
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

    @objc private func handleBackgroundTap(_ gesture: UITapGestureRecognizer) {
        guard selectedClipID != nil else { return }
        // If the tap hit a ClipView, the clip's own tap recognizer handles it
        // and this fires as well — so verify the hit was on bare background.
        let point = gesture.location(in: contentView)
        for row in trackRowViews.values where row.frame.contains(point) {
            let local = gesture.location(in: row)
            for clipView in row.subviews.compactMap({ $0 as? ClipView }) {
                if clipView.frame.contains(local) { return }
            }
        }
        selectedClipID = nil
        setSelectedClipID(nil)
        onClipSelected?(nil)
    }

    @objc private func handleRulerTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: rulerView)
        seekToContentX(point.x)
    }

    @objc private func handleRulerPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: rulerView)
        seekToContentX(point.x)
    }

    // Drag the playhead itself to scrub. Gesture location is read in the
    // stable `contentView` coordinate space so mid-drag playhead relayouts
    // (from the PlaybackController feedback loop) don't confuse translation.
    @objc private func handlePlayheadPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: contentView)
        seekToContentX(point.x)
    }

    private func seekToContentX(_ x: CGFloat) {
        let seconds = max(0, Double(x) / Double(pixelsPerSecond))
        let clamped = min(seconds, timeline.duration.seconds)
        onSeek?(CMTime(seconds: clamped, preferredTimescale: 600))
    }
}
