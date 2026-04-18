import AVFoundation
import Combine
import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class ExporterTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ProjectStore!
    private var cancellables: Set<AnyCancellable> = []
    private let tb: CMTimeScale = 600

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ExporterTests-\(UUID().uuidString)", isDirectory: true)
        store = try ProjectStore(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: tb)
    }

    private func makeOutput(duration: Double = 1) throws -> CompositionBuilder.Output {
        let project = try store.create()
        try TestVideoFixtures.writeBlackMOV(
            to: project.screenURL, duration: t(duration),
            color: (255, 0, 0), withSilentAudio: true)
        try TestVideoFixtures.writeBlackMOV(
            to: project.cameraURL, duration: t(duration),
            color: (0, 255, 0))
        let screen = AVURLAsset(url: project.screenURL)
        let camera = AVURLAsset(url: project.cameraURL)
        let timeline = Timeline.fromAssets(screenAsset: screen, cameraAsset: camera)
        return try CompositionBuilder.build(
            timeline: timeline, screenAsset: screen, cameraAsset: camera,
            bubbleTimeline: BubbleTimeline(snapshots: []), screenScale: 1)
    }

    // MARK: - AC1: completes and produces a playable file

    func testPrimaryExportCompletesAndWritesFile() throws {
        let output = try makeOutput(duration: 1)
        let exporter = Exporter(
            composition: output.composition,
            videoComposition: output.videoComposition,
            audioMix: output.audioMix)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("exporter-primary-\(UUID().uuidString).mp4")

        let done = expectation(description: "export completes")
        exporter.done
            .sink { state in
                if case .completed = state { done.fulfill() }
            }
            .store(in: &cancellables)

        exporter.start(outputURL: url)
        wait(for: [done], timeout: 30.0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - AC2: progress advances monotonically

    func testProgressAdvancesMonotonically() throws {
        let output = try makeOutput(duration: 1)
        let exporter = Exporter(
            composition: output.composition,
            videoComposition: output.videoComposition,
            audioMix: output.audioMix)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("exporter-progress-\(UUID().uuidString).mp4")

        var progressHistory: [Double] = []
        exporter.$progress
            .sink { progressHistory.append($0) }
            .store(in: &cancellables)

        let done = expectation(description: "export completes")
        exporter.done
            .sink { state in
                if case .completed = state { done.fulfill() }
            }
            .store(in: &cancellables)

        exporter.start(outputURL: url)
        wait(for: [done], timeout: 30.0)

        XCTAssertFalse(progressHistory.isEmpty)
        // Every value ≥ its predecessor.
        for i in 1..<progressHistory.count {
            XCTAssertGreaterThanOrEqual(progressHistory[i], progressHistory[i - 1],
                                        "progress regressed at index \(i)")
        }
        XCTAssertEqual(progressHistory.last ?? 0, 1.0, accuracy: 0.001)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - AC3: cancel aborts and cleans up the output file

    func testCancelEndsStreamAndRemovesOutput() throws {
        let output = try makeOutput(duration: 3)
        let exporter = Exporter(
            composition: output.composition,
            videoComposition: output.videoComposition,
            audioMix: output.audioMix)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("exporter-cancel-\(UUID().uuidString).mp4")

        let finished = expectation(description: "exporter reports terminal state")
        var finalState: Exporter.State = .notStarted
        exporter.done
            .sink { s in
                finalState = s
                finished.fulfill()
            }
            .store(in: &cancellables)

        exporter.start(outputURL: url)
        // Cancel before it can finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exporter.cancel()
        }
        wait(for: [finished], timeout: 10.0)

        if case .cancelled = finalState {
            // expected path
        } else if case .completed = finalState {
            // Cancel races with a very fast export; both outcomes are acceptable
            // and don't invalidate the API contract.
        } else {
            XCTFail("unexpected terminal state: \(finalState)")
        }
        // Cancelled export must not leave an output file behind.
        if case .cancelled = finalState {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        try? FileManager.default.removeItem(at: url)
    }
}
