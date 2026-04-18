import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class SnapEngineTests: XCTestCase {

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: 600)
    }

    func testSnapsToNearestNeighborWithinThreshold() {
        let result = SnapEngine.snap(
            candidate: t(1.02),
            neighbors: [t(0), t(1), t(2)],
            thresholdSeconds: 0.05)
        XCTAssertEqual(result.seconds, 1.0, accuracy: 1e-6)
    }

    func testReturnsCandidateWhenFurtherThanThreshold() {
        let result = SnapEngine.snap(
            candidate: t(0.5),
            neighbors: [t(0), t(1), t(2)],
            thresholdSeconds: 0.1)
        XCTAssertEqual(result.seconds, 0.5, accuracy: 1e-6)
    }

    func testChoosesClosestWhenMultipleNeighborsInRange() {
        // Candidate at 1.06s with neighbors at 1.0 and 1.1, threshold 0.1.
        // Should snap to 1.1 (closer).
        let result = SnapEngine.snap(
            candidate: t(1.06),
            neighbors: [t(1.0), t(1.1)],
            thresholdSeconds: 0.1)
        XCTAssertEqual(result.seconds, 1.1, accuracy: 1e-6)
    }

    func testEmptyNeighborsIsANoop() {
        let result = SnapEngine.snap(
            candidate: t(1),
            neighbors: [],
            thresholdSeconds: 1.0)
        XCTAssertEqual(result.seconds, 1.0, accuracy: 1e-6)
    }

    func testThresholdSecondsScalesWithZoom() {
        // 8pt threshold @ 40pt/s pixelsPerSecond → 0.2s.
        XCTAssertEqual(
            SnapEngine.thresholdSeconds(forPoints: 8, pixelsPerSecond: 40),
            0.2,
            accuracy: 1e-6)
        // 8pt @ 200pt/s → 0.04s (tighter snap when zoomed in, as you'd want).
        XCTAssertEqual(
            SnapEngine.thresholdSeconds(forPoints: 8, pixelsPerSecond: 200),
            0.04,
            accuracy: 1e-6)
    }
}

final class TrimMathTests: XCTestCase {

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: 600)
    }

    private func makeClipAndTimeline() -> (Timeline, UUID) {
        let clip = Clip(
            sourceID: .screen,
            sourceRange: CMTimeRange(start: .zero, duration: t(4)),
            timelineRange: CMTimeRange(start: .zero, duration: t(4)),
            speed: 1.0,
            volume: 1.0)
        let track = Track(kind: .video, sourceBinding: .screen, clips: [clip])
        return (Timeline(tracks: [track], duration: t(4)), clip.id)
    }

    func testTrimStartMovesLeftEdgeTimelineAndSource() {
        let (timeline, id) = makeClipAndTimeline()
        let trimmed = timeline.trimming(
            clipID: id,
            edge: .start,
            newSourceRange: CMTimeRange(start: t(1), duration: t(3)))
        let clip = trimmed.tracks[0].clips[0]
        XCTAssertEqual(clip.sourceRange.start.seconds, 1.0, accuracy: 1e-6)
        XCTAssertEqual(clip.timelineRange.duration.seconds, 3.0, accuracy: 1e-6)
        XCTAssertEqual(clip.timelineRange.end.seconds, 4.0, accuracy: 1e-6,
                       "right edge stays anchored")
    }

    func testTrimEndShrinksRightEdge() {
        let (timeline, id) = makeClipAndTimeline()
        let trimmed = timeline.trimming(
            clipID: id,
            edge: .end,
            newSourceRange: CMTimeRange(start: .zero, duration: t(2)))
        let clip = trimmed.tracks[0].clips[0]
        XCTAssertEqual(clip.sourceRange.duration.seconds, 2.0, accuracy: 1e-6)
        XCTAssertEqual(clip.timelineRange.duration.seconds, 2.0, accuracy: 1e-6)
        XCTAssertEqual(clip.timelineRange.start.seconds, 0.0, accuracy: 1e-6)
    }

    func testTrimUndoIsSingleStep() {
        let (timeline, id) = makeClipAndTimeline()
        let store = EditStore(timeline: timeline)
        let before = store.timeline
        store.apply(name: "Trim") {
            $0.trimming(clipID: id, edge: .end,
                        newSourceRange: CMTimeRange(start: .zero, duration: t(2)))
        }
        XCTAssertEqual(store.timeline.tracks[0].clips[0].timelineRange.duration.seconds, 2.0,
                       accuracy: 1e-6)
        store.undo()
        XCTAssertEqual(store.timeline, before)
    }
}
