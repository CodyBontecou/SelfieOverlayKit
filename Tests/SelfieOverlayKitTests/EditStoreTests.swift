import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class EditStoreTests: XCTestCase {

    private let tb: CMTimeScale = 600

    private func makeStore() -> (EditStore, Clip, UUID) {
        let clip = Clip(
            sourceID: .screen,
            sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: tb)),
            timelineRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: tb)))
        let trackID = UUID()
        let track = Track(id: trackID, kind: .video, sourceBinding: .screen, clips: [clip])
        let timeline = Timeline(tracks: [track], duration: CMTime(seconds: 10, preferredTimescale: tb))
        let undo = UndoManager()
        return (EditStore(timeline: timeline, undoManager: undo), clip, trackID)
    }

    func testApplyMutatesAndRegistersUndo() {
        let (store, clip, _) = makeStore()
        let before = store.timeline
        store.apply { $0.settingSpeed(clipID: clip.id, 2.0) }
        XCTAssertEqual(store.timeline.tracks[0].clips[0].speed, 2.0)
        XCTAssertTrue(store.canUndo)
        XCTAssertNotEqual(store.timeline, before)
    }

    func testUndoRestoresPreviousTimeline() {
        let (store, clip, _) = makeStore()
        let initial = store.timeline
        store.apply { $0.settingSpeed(clipID: clip.id, 2.0) }
        store.undo()
        XCTAssertEqual(store.timeline, initial)
    }

    func testUndoRedoRoundtripIsIdentity() {
        let (store, clip, _) = makeStore()
        let initial = store.timeline
        store.apply { $0.settingSpeed(clipID: clip.id, 2.0) }
        let afterMutation = store.timeline
        store.undo()
        XCTAssertEqual(store.timeline, initial)
        store.redo()
        XCTAssertEqual(store.timeline, afterMutation)
    }

    func testMultipleMutationsUndoInReverseOrder() {
        let (store, clip, trackID) = makeStore()
        let s0 = store.timeline
        store.apply { $0.settingSpeed(clipID: clip.id, 2.0) }
        let s1 = store.timeline
        store.apply { $0.splitting(at: CMTime(seconds: 2, preferredTimescale: tb), trackID: trackID) }
        let s2 = store.timeline
        XCTAssertNotEqual(s1, s2)

        store.undo()
        XCTAssertEqual(store.timeline, s1)
        store.undo()
        XCTAssertEqual(store.timeline, s0)

        store.redo()
        XCTAssertEqual(store.timeline, s1)
        store.redo()
        XCTAssertEqual(store.timeline, s2)
    }

    func testNoOpMutationDoesNotRegisterUndo() {
        let (store, _, _) = makeStore()
        store.apply { $0 } // identity
        XCTAssertFalse(store.canUndo)
    }
}
