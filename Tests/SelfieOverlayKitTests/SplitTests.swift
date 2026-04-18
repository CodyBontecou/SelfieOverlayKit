import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class SplitTests: XCTestCase {

    private let tb: CMTimeScale = 600

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: tb)
    }

    /// Two-second clip on a screen video track, occupying [0, 2]s with
    /// speed 1.5 and volume 0.6 so we can verify both propagate through
    /// the split.
    private func makeTimelineWithOneClip() -> (Timeline, UUID, UUID) {
        let clip = Clip(
            sourceID: .screen,
            sourceRange: CMTimeRange(start: .zero, duration: t(3)),
            timelineRange: CMTimeRange(start: .zero, duration: t(2)),
            speed: 1.5,
            volume: 0.6)
        let trackID = UUID()
        let track = Track(id: trackID, kind: .video, sourceBinding: .screen, clips: [clip])
        return (Timeline(tracks: [track], duration: t(2)), trackID, clip.id)
    }

    // MARK: - AC: split produces two clips, the seam is continuous

    func testSplitProducesTwoContiguousClips() {
        let (timeline, trackID, _) = makeTimelineWithOneClip()
        let split = timeline.splitting(at: t(1.2), trackID: trackID)

        XCTAssertEqual(split.tracks[0].clips.count, 2)
        let left = split.tracks[0].clips[0]
        let right = split.tracks[0].clips[1]

        // Timeline edges meet at the split point.
        XCTAssertEqual(left.timelineRange.end.seconds, 1.2, accuracy: 1e-6)
        XCTAssertEqual(right.timelineRange.start.seconds, 1.2, accuracy: 1e-6)

        // Source edges meet at the mapped source time: sourceStart + localT·speed
        // = 0 + 1.2·1.5 = 1.8.
        XCTAssertEqual(left.sourceRange.end.seconds, 1.8, accuracy: 1e-6)
        XCTAssertEqual(right.sourceRange.start.seconds, 1.8, accuracy: 1e-6)
    }

    // MARK: - AC: split preserves speed + volume

    func testSplitPreservesSpeedAndVolume() {
        let (timeline, trackID, _) = makeTimelineWithOneClip()
        let split = timeline.splitting(at: t(1), trackID: trackID)
        XCTAssertEqual(split.tracks[0].clips.count, 2)
        XCTAssertEqual(split.tracks[0].clips[0].speed, 1.5, accuracy: 1e-6)
        XCTAssertEqual(split.tracks[0].clips[1].speed, 1.5, accuracy: 1e-6)
        XCTAssertEqual(split.tracks[0].clips[0].volume, 0.6, accuracy: 1e-6)
        XCTAssertEqual(split.tracks[0].clips[1].volume, 0.6, accuracy: 1e-6)
    }

    // MARK: - AC: undo returns to a single clip

    func testUndoOfSplitRestoresOriginalTimeline() {
        let (timeline, trackID, _) = makeTimelineWithOneClip()
        let store = EditStore(timeline: timeline)
        let before = store.timeline
        store.apply(name: "Split") { $0.splitting(at: t(1), trackID: trackID) }
        XCTAssertEqual(store.timeline.tracks[0].clips.count, 2)
        store.undo()
        XCTAssertEqual(store.timeline, before)
        XCTAssertEqual(store.timeline.tracks[0].clips.count, 1)
    }

    // MARK: - AC: split at an isolated edge snaps inside so the user sees feedback

    func testSplitAtIsolatedClipStartSnapsInside() {
        let (timeline, trackID, _) = makeTimelineWithOneClip()
        let out = timeline.splitting(at: .zero, trackID: trackID)
        XCTAssertEqual(out.tracks[0].clips.count, 2,
                       "split at clip start must snap rather than silently no-op")
        XCTAssertEqual(out.tracks[0].clips[0].timelineRange.start, .zero)
    }

    func testSplitAtIsolatedClipEndSnapsInside() {
        let (timeline, trackID, _) = makeTimelineWithOneClip()
        let out = timeline.splitting(at: t(2), trackID: trackID)
        XCTAssertEqual(out.tracks[0].clips.count, 2,
                       "split at clip end must snap rather than silently no-op")
        XCTAssertEqual(out.tracks[0].clips[1].timelineRange.end, t(2))
    }
}
