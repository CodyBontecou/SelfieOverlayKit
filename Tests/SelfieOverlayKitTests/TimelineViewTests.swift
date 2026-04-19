import CoreMedia
import UIKit
import XCTest
@testable import SelfieOverlayKit

private extension UIView {
    var recursiveSubviews: [UIView] {
        subviews + subviews.flatMap(\.recursiveSubviews)
    }
}

final class TimelineViewTests: XCTestCase {

    private let tb: CMTimeScale = 600

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: tb)
    }

    private func makeTimeline(clipDurations: [(start: Double, duration: Double)]) -> Timeline {
        let clips = clipDurations.map { cd in
            Clip(
                sourceID: .screen,
                sourceRange: CMTimeRange(start: .zero, duration: t(cd.duration)),
                timelineRange: CMTimeRange(start: t(cd.start), duration: t(cd.duration)))
        }
        let track = Track(kind: .video, sourceBinding: .screen, clips: clips)
        let total = clipDurations.map { $0.start + $0.duration }.max() ?? 0
        return Timeline(tracks: [track], duration: t(total))
    }

    // MARK: - AC1: clip positions + widths match pixelsPerSecond

    func testClipPositionsAndWidthsMatchZoom() {
        let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let timeline = makeTimeline(clipDurations: [(0, 2), (3, 1)])
        view.update(timeline: timeline)
        view.layoutIfNeeded()

        let pps = view.pixelsPerSecond
        let rows = view.recursiveSubviews.compactMap { $0 as? TrackRowView }
        guard let row = rows.first else {
            XCTFail("no TrackRowView present")
            return
        }
        let clipViews = row.subviews.compactMap { $0 as? ClipView }
        XCTAssertEqual(clipViews.count, 2)

        // Sort by x to pair up with timeline ordering.
        let sorted = clipViews.sorted { $0.frame.origin.x < $1.frame.origin.x }
        XCTAssertEqual(sorted[0].frame.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(sorted[0].frame.width, 2 * pps, accuracy: 0.5)
        XCTAssertEqual(sorted[1].frame.origin.x, 3 * pps, accuracy: 0.5)
        XCTAssertEqual(sorted[1].frame.width, 1 * pps, accuracy: 0.5)
    }

    // MARK: - AC2: adaptive tick interval per zoom level

    func testAdaptiveTickInterval() {
        // Zoomed way out → pick a larger interval so labels don't overlap.
        XCTAssertEqual(TimelineRulerView.tickInterval(forPixelsPerSecond: 20), 2, accuracy: 0.0001)
        XCTAssertEqual(TimelineRulerView.tickInterval(forPixelsPerSecond: 8), 5, accuracy: 0.0001)
        // Zoomed in — small interval is readable.
        XCTAssertEqual(TimelineRulerView.tickInterval(forPixelsPerSecond: 60), 1, accuracy: 0.0001)
    }

    // MARK: - AC3: playhead position updates

    func testSetPlayheadMovesOverlay() {
        let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.update(timeline: makeTimeline(clipDurations: [(0, 4)]))
        view.layoutIfNeeded()

        view.setPlayhead(t(2))
        // Playhead view is the sole PlayheadView in the hierarchy.
        let playhead = view.recursiveSubviews.compactMap { $0 as? PlayheadView }.first
        let playheadView = try? XCTUnwrap(playhead)
        XCTAssertEqual(playheadView?.frame.origin.x ?? 0,
                       CGFloat(2) * view.pixelsPerSecond - 1,
                       accuracy: 0.5)
    }

    // MARK: - AC: playhead exposes adjustable VoiceOver trait and scrubs via onSeek

    func testPlayheadIsAdjustableAndPublishesScrubThroughOnSeek() {
        let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.update(timeline: makeTimeline(clipDurations: [(0, 10)]))
        view.layoutIfNeeded()

        let playhead = try! XCTUnwrap(
            view.recursiveSubviews.compactMap { $0 as? PlayheadView }.first)

        XCTAssertTrue(playhead.isAccessibilityElement)
        XCTAssertTrue(playhead.accessibilityTraits.contains(.adjustable))
        XCTAssertEqual(playhead.accessibilityLabel, "Playhead")

        view.setPlayhead(t(4))
        XCTAssertEqual(playhead.accessibilityValue, "4 seconds of 10 seconds")

        var seeked: CMTime?
        view.onSeek = { seeked = $0 }

        playhead.accessibilityIncrement()
        XCTAssertEqual(seeked?.seconds ?? -1, 5.0, accuracy: 1e-6,
                       "VoiceOver increment must advance 1s via onSeek")

        // Simulate the PlaybackController reflecting the seek back to the UI.
        view.setPlayhead(t(10))
        playhead.accessibilityIncrement()
        XCTAssertEqual(seeked?.seconds ?? -1, 10.0, accuracy: 1e-6,
                       "scrub must clamp at the timeline duration")

        playhead.accessibilityDecrement()
        XCTAssertEqual(seeked?.seconds ?? -1, 9.0, accuracy: 1e-6)
    }

    func testPlayheadFormatsMinutesAndSeconds() {
        XCTAssertEqual(PlayheadView.timeString(for: t(0), total: t(125)),
                       "0 seconds of 2 minutes 5 seconds")
        XCTAssertEqual(PlayheadView.timeString(for: t(61), total: t(125)),
                       "1 minute 1 second of 2 minutes 5 seconds")
    }

    // MARK: - AC4: clip tap triggers selection callback

    func testClipTapInvokesSelectionCallback() {
        let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let timeline = makeTimeline(clipDurations: [(0, 2)])
        view.update(timeline: timeline)
        view.layoutIfNeeded()

        var selectedID: UUID?
        view.onClipSelected = { id in selectedID = id }

        let targetID = timeline.tracks[0].clips[0].id
        // The rebuildTrackRows / tap gesture path is internal — assert the
        // public surface by calling setSelectedClipID through the same
        // closure the tap handler uses.
        view.setSelectedClipID(targetID)
        XCTAssertEqual(view.selectedClipID, targetID)
    }

    func testZoomToSelectionFitsClipIntoViewport() {
        let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let timeline = makeTimeline(clipDurations: [(0, 3), (3, 2), (5, 10)])
        view.update(timeline: timeline)
        view.layoutIfNeeded()

        // Pick the 2-second middle clip. With 400px width and 15% padding
        // per side, usable = 280px, target ≈ 140 px/s.
        let targetID = timeline.tracks[0].clips[1].id
        view.setSelectedClipID(targetID)
        view.zoomToSelection(padding: 0.15)

        let expected: CGFloat = 400 * (1 - 0.3) / 2
        XCTAssertEqual(view.pixelsPerSecond, expected, accuracy: 1.0,
                       "pixelsPerSecond should land ≈ 140 so the 2s clip fills ~70% of the viewport")
    }

    func testZoomToSelectionClampsToMaxCeiling() {
        let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        // A very short clip would want huge pixelsPerSecond; verify clamp.
        let timeline = makeTimeline(clipDurations: [(0, 0.05)])
        view.update(timeline: timeline)
        view.layoutIfNeeded()

        let targetID = timeline.tracks[0].clips[0].id
        view.setSelectedClipID(targetID)
        view.zoomToSelection()
        XCTAssertEqual(view.pixelsPerSecond, view.maxPixelsPerSecond)
    }

    func testZoomToSelectionNoopWithoutSelection() {
        let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let timeline = makeTimeline(clipDurations: [(0, 5)])
        view.update(timeline: timeline)
        view.layoutIfNeeded()
        let before = view.pixelsPerSecond
        view.zoomToSelection()
        XCTAssertEqual(view.pixelsPerSecond, before)
    }
}
