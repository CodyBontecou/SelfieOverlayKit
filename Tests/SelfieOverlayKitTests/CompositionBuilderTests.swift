import AVFoundation
import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class CompositionBuilderTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ProjectStore!
    private let tb: CMTimeScale = 600

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CompositionBuilderTests-\(UUID().uuidString)", isDirectory: true)
        store = try ProjectStore(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: tb)
    }

    /// Build a 2s project with silent audio on the screen source (matches how
    /// ReplayKit embeds the mic track into the screen `.mov`).
    private func makeAssetsAndProject(duration: CMTime) throws -> (EditorProject, AVAsset, AVAsset) {
        let project = try store.create()
        try TestVideoFixtures.writeBlackMOV(
            to: project.screenURL, duration: duration, withSilentAudio: true)
        try TestVideoFixtures.writeBlackMOV(
            to: project.cameraURL, duration: duration)
        return (project, AVURLAsset(url: project.screenURL), AVURLAsset(url: project.cameraURL))
    }

    // MARK: - AC1: trivial timeline builds a playable composition

    func testTrivialTimelineBuildsCompositionWithVideoAndAudio() throws {
        let (_, screen, camera) = try makeAssetsAndProject(duration: t(2))
        let timeline = Timeline.fromAssets(screenAsset: screen, cameraAsset: camera)

        // fromAssets puts one audio track (.mic) alongside the two video tracks
        // when the screen source has audio.
        XCTAssertEqual(timeline.tracks.count, 3)

        let output = CompositionBuilder.build(
            timeline: timeline, screenAsset: screen, cameraAsset: camera)
        let videoTracks = output.composition.tracks(withMediaType: .video)
        let audioTracks = output.composition.tracks(withMediaType: .audio)

        XCTAssertEqual(videoTracks.count, 2)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertGreaterThan(output.composition.duration.seconds, 1.5)

        // Video composition uses the custom BubbleVideoCompositor; there is
        // one instruction per screen-track clip (here, one full-length clip).
        XCTAssertEqual(output.videoComposition.instructions.count, 1)
        XCTAssertTrue(output.videoComposition.instructions.first is BubbleCompositionInstruction)
        XCTAssertTrue(output.videoComposition.customVideoCompositorClass == BubbleVideoCompositor.self)

        // Audio mix has one input parameters entry per audio track.
        XCTAssertEqual(output.audioMix.inputParameters.count, 1)
    }

    // MARK: - AC2: speed = 2 halves both video + audio timeline duration, keeping A/V locked

    func testSpeedTwoHalvesBothVideoAndAudioInLockstep() throws {
        let (_, screen, camera) = try makeAssetsAndProject(duration: t(2))
        var timeline = Timeline.fromAssets(screenAsset: screen, cameraAsset: camera)

        // Pair the screen video clip and the mic audio clip both at 2x.
        let screenVideoTrack = timeline.tracks.first { $0.kind == .video && $0.sourceBinding == .screen }!
        let micTrack = timeline.tracks.first { $0.kind == .audio }!
        timeline = timeline.settingSpeed(clipID: screenVideoTrack.clips[0].id, 2.0)
        timeline = timeline.settingSpeed(clipID: micTrack.clips[0].id, 2.0)

        let output = CompositionBuilder.build(
            timeline: timeline, screenAsset: screen, cameraAsset: camera)

        // The composition has two video tracks (screen + camera) and one
        // audio track (mic). After scaling, the screen video track and the
        // mic audio track should both report ~1s duration; the un-scaled
        // camera track stays at ~2s.
        let videoTracks = output.composition.tracks(withMediaType: .video)
        let audioTracks = output.composition.tracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 2)
        XCTAssertEqual(audioTracks.count, 1)

        let spedVideoTrack = videoTracks.min(by: { $0.timeRange.duration < $1.timeRange.duration })!
        let audioTrackDur = audioTracks[0].timeRange.duration.seconds
        let spedVideoDur = spedVideoTrack.timeRange.duration.seconds

        XCTAssertEqual(spedVideoDur, 1.0, accuracy: 0.1,
                       "screen video track should be re-timed to 1s at 2x speed")
        XCTAssertEqual(audioTrackDur, 1.0, accuracy: 0.1,
                       "mic audio track should be re-timed to 1s at 2x speed")
        XCTAssertEqual(spedVideoDur, audioTrackDur, accuracy: 0.05,
                       "video + audio must scale in lockstep or A/V drifts")
    }

    // MARK: - AC3: volume < 1 is reflected in the audio mix parameters

    func testVolumeBelowOneIsAppliedToAudioMix() throws {
        let (_, screen, camera) = try makeAssetsAndProject(duration: t(2))
        var timeline = Timeline.fromAssets(screenAsset: screen, cameraAsset: camera)
        let micClipID = timeline.tracks.first(where: { $0.kind == .audio })!.clips[0].id
        timeline = timeline.settingVolume(clipID: micClipID, 0.25)

        let output = CompositionBuilder.build(
            timeline: timeline, screenAsset: screen, cameraAsset: camera)

        XCTAssertEqual(output.audioMix.inputParameters.count, 1)
        let params = output.audioMix.inputParameters[0]
        var startVolume: Float = 0
        var endVolume: Float = 0
        var timeRange = CMTimeRange.zero
        let found = params.getVolumeRamp(
            for: .zero,
            startVolume: &startVolume,
            endVolume: &endVolume,
            timeRange: &timeRange)
        XCTAssertTrue(found, "expected a volume keyframe at t=0")
        XCTAssertEqual(startVolume, 0.25, accuracy: 1e-6)
    }

    func testPitchAlgorithmIsSpectralSoSpeedChangesPreservePitch() throws {
        let (_, screen, camera) = try makeAssetsAndProject(duration: t(1))
        let timeline = Timeline.fromAssets(screenAsset: screen, cameraAsset: camera)

        let output = CompositionBuilder.build(
            timeline: timeline, screenAsset: screen, cameraAsset: camera)
        XCTAssertEqual(output.audioMix.inputParameters.first?.audioTimePitchAlgorithm, .spectral)
    }
}
