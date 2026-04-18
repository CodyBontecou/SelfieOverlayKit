import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class TimelineTests: XCTestCase {

    // MARK: - Helpers

    private let tb: CMTimeScale = 600

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: tb)
    }

    private func range(_ s: Double, duration d: Double) -> CMTimeRange {
        CMTimeRange(start: t(s), duration: t(d))
    }

    /// Fresh two-track timeline with one video clip per track, both 10s long
    /// mapped 1:1 from source to timeline.
    private func makeTimeline() -> Timeline {
        let screenClip = Clip(
            sourceID: .screen,
            sourceRange: range(0, duration: 10),
            timelineRange: range(0, duration: 10))
        let cameraClip = Clip(
            sourceID: .camera,
            sourceRange: range(0, duration: 10),
            timelineRange: range(0, duration: 10))
        return Timeline(
            tracks: [
                Track(kind: .video, sourceBinding: .screen, clips: [screenClip]),
                Track(kind: .video, sourceBinding: .camera, clips: [cameraClip])
            ],
            duration: t(10))
    }

    // MARK: - Purity

    func testMutationsReturnNewTimelineWithoutSideEffects() {
        let tl = makeTimeline()
        let clip = tl.tracks[0].clips[0]
        _ = tl.settingSpeed(clipID: clip.id, 2.0)
        XCTAssertEqual(tl.tracks[0].clips[0].speed, 1.0,
                       "original Timeline must not mutate")
    }

    // MARK: - Trim

    func testTrimStartMovesLeftEdgeRightEdgeStays() {
        let tl = makeTimeline()
        let clip = tl.tracks[0].clips[0]
        let newSource = range(3, duration: 7)
        let out = tl.trimming(clipID: clip.id, edge: .start, newSourceRange: newSource)
        let trimmed = out.tracks[0].clips[0]
        XCTAssertEqual(trimmed.sourceRange, newSource)
        XCTAssertEqual(trimmed.timelineRange.end, t(10))
        XCTAssertEqual(trimmed.timelineRange.start, t(3))
        XCTAssertEqual(trimmed.timelineRange.duration, t(7))
    }

    func testTrimEndShortensRightEdge() {
        let tl = makeTimeline()
        let clip = tl.tracks[0].clips[0]
        let newSource = range(0, duration: 4)
        let out = tl.trimming(clipID: clip.id, edge: .end, newSourceRange: newSource)
        let trimmed = out.tracks[0].clips[0]
        XCTAssertEqual(trimmed.sourceRange, newSource)
        XCTAssertEqual(trimmed.timelineRange.start, .zero)
        XCTAssertEqual(trimmed.timelineRange.duration, t(4))
        XCTAssertEqual(trimmed.timelineRange.end, t(4))
    }

    func testTrimAtSpeed2TimelineDurationIsHalfSource() {
        let clip = Clip(
            sourceID: .screen,
            sourceRange: range(0, duration: 10),
            timelineRange: range(0, duration: 5),
            speed: 2.0)
        let tl = Timeline(
            tracks: [Track(kind: .video, sourceBinding: .screen, clips: [clip])],
            duration: t(5))
        let out = tl.trimming(clipID: clip.id, edge: .end, newSourceRange: range(0, duration: 6))
        let trimmed = out.tracks[0].clips[0]
        XCTAssertEqual(trimmed.timelineRange.duration.seconds, 3.0, accuracy: 1e-6)
    }

    // MARK: - Split

    func testSplittingInTheMiddleProducesTwoClips() {
        let tl = makeTimeline()
        let track = tl.tracks[0]
        let out = tl.splitting(at: t(4), trackID: track.id)
        let clips = out.tracks[0].clips
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].timelineRange.start, .zero)
        XCTAssertEqual(clips[0].timelineRange.end, t(4))
        XCTAssertEqual(clips[1].timelineRange.start, t(4))
        XCTAssertEqual(clips[1].timelineRange.end, t(10))
        XCTAssertEqual(clips[0].sourceRange.end, t(4))
        XCTAssertEqual(clips[1].sourceRange.start, t(4))
    }

    func testSplitOnEdgeIsNoop() {
        let tl = makeTimeline()
        let track = tl.tracks[0]
        XCTAssertEqual(tl.splitting(at: .zero, trackID: track.id), tl)
        XCTAssertEqual(tl.splitting(at: t(10), trackID: track.id), tl)
    }

    func testSplitAtSpeed2HalvesSourceDifferently() {
        let clip = Clip(
            sourceID: .screen,
            sourceRange: range(0, duration: 10),
            timelineRange: range(0, duration: 5),
            speed: 2.0)
        let track = Track(kind: .video, sourceBinding: .screen, clips: [clip])
        let tl = Timeline(tracks: [track], duration: t(5))
        let out = tl.splitting(at: t(2), trackID: track.id)
        let clips = out.tracks[0].clips
        XCTAssertEqual(clips.count, 2)
        // 2 timeline seconds * 2x speed = 4 source seconds consumed by first half
        XCTAssertEqual(clips[0].sourceRange.end.seconds, 4.0, accuracy: 1e-6)
        XCTAssertEqual(clips[1].sourceRange.start.seconds, 4.0, accuracy: 1e-6)
    }

    // MARK: - Remove

    func testRemoveDeletesClip() {
        let tl = makeTimeline()
        let clipID = tl.tracks[1].clips[0].id
        let out = tl.removing(clipID: clipID)
        XCTAssertTrue(out.tracks[1].clips.isEmpty)
        XCTAssertEqual(out.tracks[0].clips.count, 1)
    }

    // MARK: - Speed

    func testSettingSpeedScalesTimelineDurationKeepingStart() {
        let tl = makeTimeline()
        let clip = tl.tracks[0].clips[0]
        let out = tl.settingSpeed(clipID: clip.id, 2.0)
        let updated = out.tracks[0].clips[0]
        XCTAssertEqual(updated.speed, 2.0)
        XCTAssertEqual(updated.sourceRange, clip.sourceRange, "speed must not change source slice")
        XCTAssertEqual(updated.timelineRange.start, .zero)
        XCTAssertEqual(updated.timelineRange.duration.seconds, 5.0, accuracy: 1e-6)
    }

    // MARK: - Volume

    func testSettingVolumeUpdatesClip() {
        let tl = makeTimeline()
        let clip = tl.tracks[0].clips[0]
        let out = tl.settingVolume(clipID: clip.id, 0.4)
        XCTAssertEqual(out.tracks[0].clips[0].volume, 0.4, accuracy: 1e-6)
    }

    func testSettingVolumeClampsToUnitRange() {
        let tl = makeTimeline()
        let clip = tl.tracks[0].clips[0]
        XCTAssertEqual(tl.settingVolume(clipID: clip.id, -1).tracks[0].clips[0].volume, 0.0)
        XCTAssertEqual(tl.settingVolume(clipID: clip.id, 2.5).tracks[0].clips[0].volume, 1.0)
    }
}
