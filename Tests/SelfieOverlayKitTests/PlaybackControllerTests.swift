import AVFoundation
import Combine
import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class PlaybackControllerTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ProjectStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PlaybackControllerTests-\(UUID().uuidString)", isDirectory: true)
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
        CMTime(seconds: s, preferredTimescale: 600)
    }

    /// Builds a 2s project with matching-length fixtures so the controller has
    /// something real to feed AVPlayerItem.
    private func makeProjectAndTimeline() throws -> (EditorProject, Timeline) {
        let project = try store.create()
        try TestVideoFixtures.writeBlackMOV(
            to: project.screenURL, duration: t(2), color: (255, 0, 0))
        try TestVideoFixtures.writeBlackMOV(
            to: project.cameraURL, duration: t(2), color: (0, 255, 0))
        let screenAsset = AVURLAsset(url: project.screenURL)
        let cameraAsset = AVURLAsset(url: project.cameraURL)
        let timeline = Timeline.fromAssets(screenAsset: screenAsset, cameraAsset: cameraAsset)
        return (project, timeline)
    }

    // MARK: - AC1: mutations trigger rebuild, same player instance

    func testMutationTriggersRebuildOnSamePlayer() throws {
        let (project, timeline) = try makeProjectAndTimeline()
        let editStore = EditStore(timeline: timeline)
        let controller = PlaybackController(
            editStore: editStore,
            project: project,
            rebuildDebounce: 0.01)

        let originalItem = controller.player.currentItem
        let originalPlayer = controller.player
        let initialCount = controller.rebuildCount

        // Trim the screen clip.
        let clipID = timeline.tracks[0].clips[0].id
        let newSource = CMTimeRange(
            start: .zero, duration: t(1))
        editStore.apply { $0.trimming(clipID: clipID, edge: .end, newSourceRange: newSource) }

        let rebuilt = expectation(description: "rebuildCount increments")
        controller.$rebuildCount
            .dropFirst()
            .sink { _ in rebuilt.fulfill() }
            .store(in: &cancellables)
        wait(for: [rebuilt], timeout: 0.5)

        XCTAssertGreaterThan(controller.rebuildCount, initialCount)
        XCTAssertTrue(controller.player === originalPlayer,
                      "the AVPlayer instance must be reused across rebuilds")
        XCTAssertFalse(controller.player.currentItem === originalItem,
                       "a new AVPlayerItem must replace the old one")
    }

    // MARK: - AC2: debounce — 5 rapid mutations within 50ms produce exactly 1 rebuild

    func testRapidMutationsDebounceToSingleRebuild() throws {
        let (project, timeline) = try makeProjectAndTimeline()
        let editStore = EditStore(timeline: timeline)
        let controller = PlaybackController(
            editStore: editStore,
            project: project,
            rebuildDebounce: 0.05)

        let baseline = controller.rebuildCount
        let clipID = timeline.tracks[0].clips[0].id

        // Fire 5 mutations in rapid succession (each one a setSpeed tweak so
        // Timeline produces a distinct value and apply() registers).
        for i in 1...5 {
            editStore.apply {
                $0.settingSpeed(clipID: clipID, 1.0 + Double(i) * 0.1)
            }
        }

        // Wait past the debounce window and confirm exactly one rebuild
        // landed from those 5 mutations.
        let done = expectation(description: "debounce window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 1.0)

        XCTAssertEqual(controller.rebuildCount - baseline, 1,
                       "5 mutations in one debounce window must collapse to a single rebuild")
    }

    // MARK: - AC3: seek emits on currentTime publisher

    func testSeekEmitsOnCurrentTimePublisher() throws {
        let (project, timeline) = try makeProjectAndTimeline()
        let editStore = EditStore(timeline: timeline)
        let controller = PlaybackController(
            editStore: editStore,
            project: project,
            rebuildDebounce: 0.01)

        let emitted = expectation(description: "currentTime emits on seek")
        var received: CMTime = .invalid
        controller.currentTime
            .sink { time in
                received = time
                emitted.fulfill()
            }
            .store(in: &cancellables)

        controller.seek(to: t(0.5))
        wait(for: [emitted], timeout: 1.0)
        XCTAssertEqual(received.seconds, 0.5, accuracy: 0.05)
    }

    // MARK: - AC4: playhead clamps across rebuilds

    func testPlayheadClampsToNewDurationAfterTrim() throws {
        let (project, timeline) = try makeProjectAndTimeline()
        let editStore = EditStore(timeline: timeline)
        let controller = PlaybackController(
            editStore: editStore,
            project: project,
            rebuildDebounce: 0.01)

        let seeked = expectation(description: "seek completes")
        controller.player.seek(to: t(1.8),
                               toleranceBefore: .zero,
                               toleranceAfter: .zero) { _ in seeked.fulfill() }
        wait(for: [seeked], timeout: 1.0)

        // Trim to 1s total duration so 1.8s is now out of range.
        let clipID = timeline.tracks[0].clips[0].id
        editStore.apply {
            $0.trimming(clipID: clipID,
                        edge: .end,
                        newSourceRange: CMTimeRange(start: .zero, duration: t(1)))
        }

        let rebuilt = expectation(description: "rebuild after trim")
        controller.$rebuildCount
            .dropFirst()
            .sink { _ in rebuilt.fulfill() }
            .store(in: &cancellables)
        wait(for: [rebuilt], timeout: 1.0)

        // Give the internal clamped-seek a moment to settle.
        let settled = expectation(description: "clamp seek settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 1.0)

        let now = controller.player.currentTime().seconds
        let itemDuration = controller.player.currentItem?.asset.duration.seconds ?? 0
        XCTAssertLessThanOrEqual(now, itemDuration + 0.05,
                                 "playhead must clamp to new, shorter duration after trim")
    }
}
