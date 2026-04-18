import AVFoundation
import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class VolumeInspectorTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ProjectStore!
    private let tb: CMTimeScale = 600

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VolumeInspectorTests-\(UUID().uuidString)", isDirectory: true)
        store = try ProjectStore(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: tb)
    }

    // MARK: - Formatter

    func testFormatVolumeRendersPercentages() {
        XCTAssertEqual(ClipInspectorView.formatVolume(0), "0%")
        XCTAssertEqual(ClipInspectorView.formatVolume(1), "100%")
        XCTAssertEqual(ClipInspectorView.formatVolume(2), "200%")
        XCTAssertEqual(ClipInspectorView.formatVolume(0.5), "50%")
    }

    // MARK: - Settings volume propagates to AVAudioMix through CompositionBuilder

    func testMutingAudioClipSetsVolumeZeroInAudioMix() throws {
        let project = try store.create()
        try TestVideoFixtures.writeBlackMOV(
            to: project.screenURL, duration: t(2), color: (255, 0, 0), withSilentAudio: true)
        try TestVideoFixtures.writeBlackMOV(
            to: project.cameraURL, duration: t(2), color: (0, 255, 0))

        let screen = AVURLAsset(url: project.screenURL)
        let camera = AVURLAsset(url: project.cameraURL)
        var timeline = Timeline.fromAssets(screenAsset: screen, cameraAsset: camera)
        let micClipID = timeline.tracks.first(where: { $0.kind == .audio })!.clips[0].id
        timeline = timeline.settingVolume(clipID: micClipID, 0)

        let output = try CompositionBuilder.build(
            timeline: timeline,
            screenAsset: screen,
            cameraAsset: camera)

        XCTAssertEqual(output.audioMix.inputParameters.count, 1)
        let params = output.audioMix.inputParameters[0]
        var start: Float = 1
        var end: Float = 1
        var range = CMTimeRange.zero
        let found = params.getVolumeRamp(for: .zero,
                                         startVolume: &start,
                                         endVolume: &end,
                                         timeRange: &range)
        XCTAssertTrue(found)
        XCTAssertEqual(start, 0, accuracy: 1e-6, "mute (volume=0) must land at t=0")
    }

    // MARK: - Amplification above 100% clamps to 200%

    func testVolumeClampsWithinNewRange() {
        let tl = Timeline(tracks: [
            Track(kind: .audio, sourceBinding: .mic, clips: [
                Clip(sourceID: .mic,
                     sourceRange: CMTimeRange(start: .zero, duration: t(1)),
                     timelineRange: CMTimeRange(start: .zero, duration: t(1)))
            ])
        ], duration: t(1))
        let clipID = tl.tracks[0].clips[0].id

        XCTAssertEqual(tl.settingVolume(clipID: clipID, 2.5).tracks[0].clips[0].volume, 2.0,
                       "clamp above 2.0")
        XCTAssertEqual(tl.settingVolume(clipID: clipID, -0.5).tracks[0].clips[0].volume, 0.0,
                       "clamp below 0.0")
        XCTAssertEqual(tl.settingVolume(clipID: clipID, 1.5).tracks[0].clips[0].volume, 1.5,
                       "in-range value passes through")
    }
}
