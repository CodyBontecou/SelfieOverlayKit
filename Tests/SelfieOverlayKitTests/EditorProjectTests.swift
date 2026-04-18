import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class EditorProjectTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("EditorProjectTests-\(UUID().uuidString)", isDirectory: true)
        store = try ProjectStore(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Folder layout

    func testCreateProducesFolderWithStableURLs() throws {
        let project = try store.create()
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: project.folderURL.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(project.folderURL.lastPathComponent, project.id.uuidString)
        XCTAssertEqual(project.screenURL.lastPathComponent, "screen.mov")
        XCTAssertEqual(project.cameraURL.lastPathComponent, "camera.mov")
        XCTAssertEqual(project.bubbleTimelineURL.lastPathComponent, "bubble.json")
    }

    // MARK: - AC: roundtrip via ProjectStore.load(id:)

    func testLoadReturnsSameProject() throws {
        let created = try store.create()
        try store.saveMetadata(created)

        // Populate payload files so the load flow mirrors real recordings.
        try Data("screen".utf8).write(to: created.screenURL)
        try Data("camera".utf8).write(to: created.cameraURL)
        let timeline = BubbleTimeline(snapshots: [
            .init(time: 0,
                  frame: CGRect(x: 10, y: 20, width: 140, height: 140),
                  shape: .circle, mirror: true, opacity: 0.9,
                  borderWidth: 2, borderHue: 0.5),
            .init(time: 1.5,
                  frame: CGRect(x: 20, y: 40, width: 140, height: 140),
                  shape: .roundedRect, mirror: false, opacity: 1.0,
                  borderWidth: 0, borderHue: 0.2)
        ])
        try store.saveBubbleTimeline(timeline, to: created)

        let loaded = try store.load(id: created.id)
        XCTAssertEqual(loaded.id, created.id)
        XCTAssertEqual(loaded.folderURL, created.folderURL)
        // ISO8601 encoding truncates to whole seconds; 1s tolerance is enough
        // for an informational timestamp.
        XCTAssertEqual(
            loaded.createdAt.timeIntervalSince1970,
            created.createdAt.timeIntervalSince1970,
            accuracy: 1.0)

        let reloadedTimeline = try store.loadBubbleTimeline(for: loaded)
        XCTAssertEqual(reloadedTimeline, timeline)
    }

    func testLoadWithoutFolderUserInfoThrows() throws {
        let created = try store.create()
        try store.saveMetadata(created)

        // Plain JSONDecoder without the userInfo key must refuse.
        let data = try Data(contentsOf: created.metadataURL)
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(EditorProject.self, from: data))
    }

    // MARK: - AC: Codable BubbleTimeline

    func testBubbleTimelineCodableRoundtrip() throws {
        let timeline = BubbleTimeline(snapshots: [
            .init(time: 0,
                  frame: CGRect(x: 1, y: 2, width: 3, height: 4),
                  shape: .circle, mirror: false, opacity: 0.5,
                  borderWidth: 1, borderHue: 0.1)
        ])
        let data = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(BubbleTimeline.self, from: data)
        XCTAssertEqual(decoded, timeline)
    }

    // MARK: - AC: folder contains the three expected files

    func testProjectFolderAfterPopulationContainsExpectedFiles() throws {
        let project = try store.create()
        try Data("screen".utf8).write(to: project.screenURL)
        try Data("camera".utf8).write(to: project.cameraURL)
        try store.saveBubbleTimeline(BubbleTimeline(snapshots: []), to: project)
        try store.saveMetadata(project)

        let entries = try FileManager.default.contentsOfDirectory(atPath: project.folderURL.path)
        XCTAssertTrue(entries.contains("screen.mov"))
        XCTAssertTrue(entries.contains("camera.mov"))
        XCTAssertTrue(entries.contains("bubble.json"))
        XCTAssertTrue(entries.contains("project.json"))
    }

    // MARK: - AC: Codable Timeline (autosave round-trip)

    func testTimelineCodableRoundtripPreservesCMTimeTimescales() throws {
        let tb: CMTimeScale = 600
        let sourceRange = CMTimeRange(
            start: CMTime(value: 120, timescale: tb),
            duration: CMTime(value: 1800, timescale: tb))
        let timelineRange = CMTimeRange(
            start: CMTime(value: 0, timescale: tb),
            duration: CMTime(value: 900, timescale: tb))
        let clip = Clip(
            sourceID: .mic,
            sourceRange: sourceRange,
            timelineRange: timelineRange,
            speed: 2.0,
            volume: 0.5)
        let track = Track(kind: .audio, sourceBinding: .mic, clips: [clip])
        let timeline = Timeline(
            tracks: [track],
            duration: CMTime(value: 2400, timescale: tb))

        let data = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)
        XCTAssertEqual(decoded, timeline)
        // Explicitly verify timescales survived — Double(seconds) would drop
        // them and break CompositionBuilder's scaleTimeRange.
        XCTAssertEqual(decoded.tracks[0].clips[0].sourceRange.start.timescale, tb)
        XCTAssertEqual(decoded.tracks[0].clips[0].sourceRange.duration.timescale, tb)
    }

    func testSaveAndLoadTimelineViaProjectStore() throws {
        let project = try store.create()
        XCTAssertNil(try store.loadTimeline(for: project),
                     "loadTimeline returns nil before any autosave write")

        let tb: CMTimeScale = 600
        let clip = Clip(
            sourceID: .screen,
            sourceRange: CMTimeRange(start: .zero,
                                     duration: CMTime(value: 600, timescale: tb)),
            timelineRange: CMTimeRange(start: .zero,
                                       duration: CMTime(value: 600, timescale: tb)))
        let track = Track(kind: .video, sourceBinding: .screen, clips: [clip])
        let timeline = Timeline(tracks: [track],
                                duration: CMTime(value: 600, timescale: tb))

        try store.saveTimeline(timeline, to: project)
        let loaded = try store.loadTimeline(for: project)
        XCTAssertEqual(loaded, timeline)
    }

    func testDeleteRemovesFolder() throws {
        let project = try store.create()
        try store.saveMetadata(project)
        try store.delete(project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.folderURL.path))
    }
}
