import AVFoundation
import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class TimelineFromProjectTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TimelineFromProjectTests-\(UUID().uuidString)", isDirectory: true)
        store = try ProjectStore(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    func testDurationClampsToShorterSourceAsset() throws {
        let project = try store.create()
        // Screen 3s, camera 2s — timeline should clamp to 2s.
        try TestVideoFixtures.writeBlackMOV(
            to: project.screenURL,
            duration: CMTime(seconds: 3, preferredTimescale: 600))
        try TestVideoFixtures.writeBlackMOV(
            to: project.cameraURL,
            duration: CMTime(seconds: 2, preferredTimescale: 600))

        let timeline = Timeline.fromProject(project)
        XCTAssertEqual(timeline.duration.seconds, 2.0, accuracy: 0.1)

        // Seed produces one video track per source; no audio track, since the
        // fixtures contain video only.
        XCTAssertEqual(timeline.tracks.count, 2)
        XCTAssertEqual(timeline.tracks.map(\.sourceBinding), [.screen, .camera])
        XCTAssertEqual(timeline.tracks.map(\.kind), [.video, .video])
        for track in timeline.tracks {
            XCTAssertEqual(track.clips.count, 1)
            XCTAssertEqual(track.clips[0].timelineRange.duration.seconds, 2.0, accuracy: 0.1)
        }
    }

    func testMicTrackSeededWhenOnlyCameraHasAudio() throws {
        let project = try store.create()
        // Silent screen, camera with audio — a realistic "mic denied on
        // screen capture but granted on camera capture" pairing.
        try TestVideoFixtures.writeBlackMOV(
            to: project.screenURL,
            duration: CMTime(seconds: 1, preferredTimescale: 600))
        try TestVideoFixtures.writeBlackMOV(
            to: project.cameraURL,
            duration: CMTime(seconds: 1, preferredTimescale: 600),
            withSilentAudio: true)

        let timeline = Timeline.fromProject(project)
        let micTracks = timeline.tracks.filter { $0.kind == .audio && $0.sourceBinding == .mic }
        XCTAssertEqual(micTracks.count, 1,
                       "mic track must be seeded when camera carries mic audio")
    }

    func testNoMicTrackWhenNeitherAssetHasAudio() throws {
        let project = try store.create()
        try TestVideoFixtures.writeBlackMOV(
            to: project.screenURL,
            duration: CMTime(seconds: 1, preferredTimescale: 600))
        try TestVideoFixtures.writeBlackMOV(
            to: project.cameraURL,
            duration: CMTime(seconds: 1, preferredTimescale: 600))

        let timeline = Timeline.fromProject(project)
        XCTAssertFalse(timeline.tracks.contains(where: { $0.kind == .audio }),
                       "no audio track expected when neither source has audio")
    }
}
