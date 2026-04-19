import AVFoundation
import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class RawExporterTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RawExporterTests-\(UUID().uuidString)", isDirectory: true)
        store = try ProjectStore(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeProject(withAudio: Bool) throws -> EditorProject {
        let project = try store.create()
        try TestVideoFixtures.writeBlackMOV(
            to: project.screenURL,
            duration: CMTime(seconds: 1, preferredTimescale: 600),
            withSilentAudio: withAudio)
        try TestVideoFixtures.writeBlackMOV(
            to: project.cameraURL,
            duration: CMTime(seconds: 1, preferredTimescale: 600))
        try store.saveBubbleTimeline(BubbleTimeline(snapshots: []), to: project)
        try store.saveMetadata(project)
        return project
    }

    private func runExport(project: EditorProject,
                           destination: URL,
                           demuxAudio: Bool) throws -> RawExportBundle {
        let exp = expectation(description: "raw export")
        var bundle: RawExportBundle?
        var error: Error?
        RawExporter.export(project: project, to: destination, demuxAudio: demuxAudio) { result in
            switch result {
            case .success(let b): bundle = b
            case .failure(let e): error = e
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 30)
        if let error { throw error }
        return try XCTUnwrap(bundle)
    }

    // MARK: - AC: produces screen.mov, camera.mov, bubble.json, audio.m4a

    func testProducesAllFourFilesWhenSourceHasAudio() throws {
        let project = try makeProject(withAudio: true)
        let destination = tempRoot.appendingPathComponent("out", isDirectory: true)

        let bundle = try runExport(project: project, destination: destination, demuxAudio: true)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: bundle.screenURL.path))
        XCTAssertTrue(fm.fileExists(atPath: bundle.cameraURL.path))
        XCTAssertTrue(fm.fileExists(atPath: bundle.bubbleTimelineURL.path))
        let audioURL = try XCTUnwrap(bundle.audioURL)
        XCTAssertTrue(fm.fileExists(atPath: audioURL.path))

        XCTAssertEqual(bundle.screenURL.lastPathComponent, "screen.mov")
        XCTAssertEqual(bundle.cameraURL.lastPathComponent, "camera.mov")
        XCTAssertEqual(bundle.bubbleTimelineURL.lastPathComponent, "bubble.json")
        XCTAssertEqual(audioURL.lastPathComponent, "audio.m4a")
    }

    // MARK: - AC: audio is stripped from screen.mov when demuxAudio=true

    func testStripsAudioFromScreenWhenDemuxed() throws {
        let project = try makeProject(withAudio: true)
        let destination = tempRoot.appendingPathComponent("out", isDirectory: true)

        let bundle = try runExport(project: project, destination: destination, demuxAudio: true)

        let strippedAsset = AVURLAsset(url: bundle.screenURL)
        XCTAssertTrue(strippedAsset.tracks(withMediaType: .audio).isEmpty,
                      "Expected no audio tracks in screen.mov after demux+strip.")
        XCTAssertFalse(strippedAsset.tracks(withMediaType: .video).isEmpty,
                       "Expected video tracks to be preserved in screen.mov.")

        let audioAsset = AVURLAsset(url: try XCTUnwrap(bundle.audioURL))
        XCTAssertFalse(audioAsset.tracks(withMediaType: .audio).isEmpty,
                       "Expected audio tracks in audio.m4a.")
    }

    // MARK: - AC: audio remains embedded in screen.mov when demuxAudio=false

    func testLeavesAudioInScreenWhenNotDemuxed() throws {
        let project = try makeProject(withAudio: true)
        let destination = tempRoot.appendingPathComponent("out", isDirectory: true)

        let bundle = try runExport(project: project, destination: destination, demuxAudio: false)

        XCTAssertNil(bundle.audioURL)
        let asset = AVURLAsset(url: bundle.screenURL)
        XCTAssertFalse(asset.tracks(withMediaType: .audio).isEmpty,
                       "Expected audio to remain embedded in screen.mov when demuxAudio=false.")
    }

    // MARK: - AC: audioURL nil when source has no audio

    func testReturnsNilAudioURLWhenSourceHasNoAudio() throws {
        let project = try makeProject(withAudio: false)
        let destination = tempRoot.appendingPathComponent("out", isDirectory: true)

        let bundle = try runExport(project: project, destination: destination, demuxAudio: true)

        XCTAssertNil(bundle.audioURL)
        // Ensure we didn't write a stray empty audio.m4a.
        let strayAudio = destination.appendingPathComponent("audio.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayAudio.path))
    }

    // MARK: - AC: demuxAudio=false skips audio extraction even with audio source

    func testSkipsAudioWhenDemuxFalse() throws {
        let project = try makeProject(withAudio: true)
        let destination = tempRoot.appendingPathComponent("out", isDirectory: true)

        let bundle = try runExport(project: project, destination: destination, demuxAudio: false)

        XCTAssertNil(bundle.audioURL)
        let strayAudio = destination.appendingPathComponent("audio.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayAudio.path))
    }

    // MARK: - Destination handling

    func testCreatesDestinationDirectoryIfMissing() throws {
        let project = try makeProject(withAudio: false)
        let destination = tempRoot.appendingPathComponent("nested/does/not/exist", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        _ = try runExport(project: project, destination: destination, demuxAudio: false)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testOverwritesExistingDestinationFiles() throws {
        let project = try makeProject(withAudio: false)
        let destination = tempRoot.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let stalePaths = [
            destination.appendingPathComponent("screen.mov"),
            destination.appendingPathComponent("camera.mov"),
            destination.appendingPathComponent("bubble.json")
        ]
        for url in stalePaths {
            try Data("stale".utf8).write(to: url)
        }

        _ = try runExport(project: project, destination: destination, demuxAudio: false)

        for url in stalePaths {
            let data = try Data(contentsOf: url)
            XCTAssertNotEqual(data, Data("stale".utf8),
                              "Expected \(url.lastPathComponent) to be overwritten by export.")
        }
    }

    func testFailsWhenDestinationIsAFile() throws {
        let project = try makeProject(withAudio: false)
        let destination = tempRoot.appendingPathComponent("not-a-directory")
        try Data().write(to: destination)

        let exp = expectation(description: "raw export")
        var error: Error?
        RawExporter.export(project: project, to: destination, demuxAudio: false) { result in
            if case .failure(let e) = result { error = e }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 30)
        guard case RawExporter.Failure.destinationNotADirectory? = (error as? RawExporter.Failure) else {
            return XCTFail("Expected destinationNotADirectory, got \(String(describing: error))")
        }
    }
}
