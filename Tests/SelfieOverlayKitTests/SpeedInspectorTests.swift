import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class SpeedInspectorTests: XCTestCase {

    private let tb: CMTimeScale = 600

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: tb)
    }

    // MARK: - log-scale slider math

    func testSliderMathRoundtrips() {
        for speed in [0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0] {
            let slider = ClipInspectorView.sliderFromSpeed(speed)
            let back = ClipInspectorView.speedFromSlider(slider)
            XCTAssertEqual(back, speed, accuracy: 0.01, "roundtrip for \(speed)")
        }
    }

    func testSliderBoundsCoverRequestedRange() {
        // Slider values -2 and 2 should be the defaults matching 0.25× and 4×.
        XCTAssertEqual(ClipInspectorView.speedFromSlider(-2), 0.25, accuracy: 1e-6)
        XCTAssertEqual(ClipInspectorView.speedFromSlider(2), 4.0, accuracy: 1e-6)
    }

    // MARK: - Paired setSpeed retimes the mic track alongside the video

    func testPairedSetSpeedRetimesAudioInLockstep() {
        let videoClip = Clip(
            sourceID: .screen,
            sourceRange: CMTimeRange(start: .zero, duration: t(2)),
            timelineRange: CMTimeRange(start: .zero, duration: t(2)))
        let audioClip = Clip(
            sourceID: .mic,
            sourceRange: CMTimeRange(start: .zero, duration: t(2)),
            timelineRange: CMTimeRange(start: .zero, duration: t(2)))
        let timeline = Timeline(tracks: [
            Track(kind: .video, sourceBinding: .screen, clips: [videoClip]),
            Track(kind: .audio, sourceBinding: .mic, clips: [audioClip])
        ], duration: t(2))

        let out = timeline.settingPairedSpeed(clipID: videoClip.id, 2.0)
        let newVideo = out.tracks[0].clips[0]
        let newAudio = out.tracks[1].clips[0]
        XCTAssertEqual(newVideo.speed, 2.0)
        XCTAssertEqual(newAudio.speed, 2.0)
        XCTAssertEqual(newVideo.timelineRange.duration.seconds, 1.0, accuracy: 0.01)
        XCTAssertEqual(newAudio.timelineRange.duration.seconds, 1.0, accuracy: 0.01)
    }

    func testPairedSetSpeedFromAudioDoesNotRetimeVideo() {
        let videoClip = Clip(
            sourceID: .screen,
            sourceRange: CMTimeRange(start: .zero, duration: t(2)),
            timelineRange: CMTimeRange(start: .zero, duration: t(2)))
        let audioClip = Clip(
            sourceID: .mic,
            sourceRange: CMTimeRange(start: .zero, duration: t(2)),
            timelineRange: CMTimeRange(start: .zero, duration: t(2)))
        let timeline = Timeline(tracks: [
            Track(kind: .video, sourceBinding: .screen, clips: [videoClip]),
            Track(kind: .audio, sourceBinding: .mic, clips: [audioClip])
        ], duration: t(2))

        let out = timeline.settingPairedSpeed(clipID: audioClip.id, 0.5)
        XCTAssertEqual(out.tracks[1].clips[0].speed, 0.5)
        XCTAssertEqual(out.tracks[0].clips[0].speed, 1.0,
                       "audio-only retime must not change the video clip's speed")
    }

    // MARK: - Undo reverts the speed change in one step

    func testUndoRevertsPairedSpeedInOneStep() {
        let videoClip = Clip(
            sourceID: .screen,
            sourceRange: CMTimeRange(start: .zero, duration: t(2)),
            timelineRange: CMTimeRange(start: .zero, duration: t(2)))
        let audioClip = Clip(
            sourceID: .mic,
            sourceRange: CMTimeRange(start: .zero, duration: t(2)),
            timelineRange: CMTimeRange(start: .zero, duration: t(2)))
        let timeline = Timeline(tracks: [
            Track(kind: .video, sourceBinding: .screen, clips: [videoClip]),
            Track(kind: .audio, sourceBinding: .mic, clips: [audioClip])
        ], duration: t(2))

        let store = EditStore(timeline: timeline)
        let before = store.timeline
        store.apply(name: "Speed") { $0.settingPairedSpeed(clipID: videoClip.id, 2.0) }
        XCTAssertEqual(store.timeline.tracks[0].clips[0].speed, 2.0)
        XCTAssertEqual(store.timeline.tracks[1].clips[0].speed, 2.0)
        store.undo()
        XCTAssertEqual(store.timeline, before, "one undo must revert both paired speed updates")
    }
}
