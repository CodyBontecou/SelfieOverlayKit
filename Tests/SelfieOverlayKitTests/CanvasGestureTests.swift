import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import UIKit
import XCTest
@testable import SelfieOverlayKit

/// Exercises the pinch/pan/tap plumbing that lets users manipulate a
/// selected clip's `canvasScale` / `canvasOffset` directly on the preview
/// without going through the timeline inspector.
final class CanvasGestureTests: XCTestCase {

    private let tb: CMTimeScale = 600

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: tb)
    }

    private func range(_ s: Double, duration d: Double) -> CMTimeRange {
        CMTimeRange(start: t(s), duration: t(d))
    }

    // MARK: - Coordinate math

    /// `.resizeAspect` letterboxes a 1080×1920 video inside a 540×1920 view
    /// — the video occupies the full height but is halved in width, with
    /// ~270pt of black bar on each side. A 10pt view delta must therefore
    /// land as ~10 canvas pixels (fitScale 0.5 → view:canvas ratio 1:2).
    func testViewDeltaConvertsThroughLetterboxScale() {
        let viewSize = CGSize(width: 540, height: 1920)
        let renderSize = CGSize(width: 1080, height: 1920)
        let delta = PreviewCanvasView.viewDeltaToCanvas(
            CGPoint(x: 50, y: -30),
            viewSize: viewSize,
            renderSize: renderSize)
        // fit = min(540/1080, 1920/1920) = 0.5 → canvas = view / 0.5 = view * 2
        XCTAssertEqual(delta.x, 100, accuracy: 1e-6)
        XCTAssertEqual(delta.y, -60, accuracy: 1e-6)
    }

    func testViewDeltaIsZeroForDegenerateSizes() {
        XCTAssertEqual(
            PreviewCanvasView.viewDeltaToCanvas(
                CGPoint(x: 10, y: 10),
                viewSize: .zero,
                renderSize: CGSize(width: 1080, height: 1920)),
            .zero)
        XCTAssertEqual(
            PreviewCanvasView.viewDeltaToCanvas(
                CGPoint(x: 10, y: 10),
                viewSize: CGSize(width: 100, height: 100),
                renderSize: .zero),
            .zero)
    }

    /// Touches outside the letterboxed video rect return nil so the tap
    /// hit-test can short-circuit instead of computing nonsensical canvas
    /// coordinates in the black bars.
    func testViewPointReturnsNilOutsideVideoRect() {
        let viewSize = CGSize(width: 540, height: 1920)
        let renderSize = CGSize(width: 1080, height: 1920)
        // Video fits the full height (fit=0.5 → 540×960). View is 1920 tall
        // but video is only 960 tall letterboxed vertically — so a point at
        // y=10 (well above the vertical inset of 480) must be outside.
        let point = CGPoint(x: 10, y: 10)
        XCTAssertNil(PreviewCanvasView.viewPointToCanvas(
            point, viewSize: viewSize, renderSize: renderSize))
    }

    /// A point on the centre of the view maps to the centre of the canvas.
    func testViewPointMapsCentreToCanvasCentre() throws {
        let viewSize = CGSize(width: 540, height: 960)
        let renderSize = CGSize(width: 1080, height: 1920)
        let centre = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let canvas = try XCTUnwrap(PreviewCanvasView.viewPointToCanvas(
            centre, viewSize: viewSize, renderSize: renderSize))
        XCTAssertEqual(canvas.x, renderSize.width / 2, accuracy: 1e-6)
        XCTAssertEqual(canvas.y, renderSize.height / 2, accuracy: 1e-6)
    }

    /// Placed rect at identity equals the natural rect — sanity check that
    /// the static helper is the same math the renderer uses.
    func testPlacedRectIdentityMatchesNatural() {
        let natural = CGRect(x: 100, y: 200, width: 400, height: 300)
        let placed = PreviewCanvasView.placedRect(
            natural: natural, transform: .identity)
        XCTAssertEqual(placed, natural)
    }

    /// A non-identity scale keeps the layer centred on its natural midpoint
    /// and offsets it by the requested translation.
    func testPlacedRectScalesAroundMidpointAndTranslates() {
        let natural = CGRect(x: 0, y: 0, width: 400, height: 400)
        let transform = BubbleOverlayRenderer.LayerTransform(
            cropRect: Clip.defaultCropRect,
            scale: 0.5,
            offset: CGPoint(x: 50, y: -25))
        let placed = PreviewCanvasView.placedRect(
            natural: natural, transform: transform)
        // 0.5× of 400×400 around the centre (200,200) → origin shifts to
        // (100,100); offset adds 50,-25.
        XCTAssertEqual(placed.midX, 250, accuracy: 1e-6)
        XCTAssertEqual(placed.midY, 175, accuracy: 1e-6)
        XCTAssertEqual(placed.width, 200, accuracy: 1e-6)
        XCTAssertEqual(placed.height, 200, accuracy: 1e-6)
    }

    /// canvasRectToView inverts viewPointToCanvas's offset — projecting a
    /// canvas-space corner back to view coords lands on the same point the
    /// forward mapping started from.
    func testCanvasRectToViewInvertsPointMapping() throws {
        let viewSize = CGSize(width: 540, height: 960)
        let renderSize = CGSize(width: 1080, height: 1920)
        let canvasPoint = CGPoint(x: 100, y: 200)
        let forward = try XCTUnwrap(PreviewCanvasView.viewPointToCanvas(
            PreviewCanvasView.canvasRectToView(
                CGRect(origin: canvasPoint, size: .zero),
                viewSize: viewSize, renderSize: renderSize).origin,
            viewSize: viewSize, renderSize: renderSize))
        XCTAssertEqual(forward.x, canvasPoint.x, accuracy: 1e-6)
        XCTAssertEqual(forward.y, canvasPoint.y, accuracy: 1e-6)
    }

    // MARK: - PreviewOverrideStore

    func testOverrideStoreGetsAndClears() {
        let store = PreviewOverrideStore()
        let id = UUID()
        XCTAssertNil(store.transform(forClip: id))
        XCTAssertTrue(store.isEmpty)

        let t = BubbleOverlayRenderer.LayerTransform(
            cropRect: Clip.defaultCropRect, scale: 2, offset: CGPoint(x: 10, y: 20))
        store.set(t, forClip: id)
        XCTAssertEqual(store.transform(forClip: id), t)
        XCTAssertFalse(store.isEmpty)

        store.set(nil, forClip: id)
        XCTAssertNil(store.transform(forClip: id))
        XCTAssertTrue(store.isEmpty)
    }

    func testOverrideStoreClearDropsAllEntries() {
        let store = PreviewOverrideStore()
        let a = UUID()
        let b = UUID()
        store.set(.identity, forClip: a)
        store.set(.identity, forClip: b)
        XCTAssertFalse(store.isEmpty)
        store.clear()
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.transform(forClip: a))
        XCTAssertNil(store.transform(forClip: b))
    }

    /// The compositor consults `overrideStore` for each instruction it
    /// renders — the instruction must carry a reference to the store that
    /// PlaybackController owns so the render path sees fresh values on
    /// every frame without a composition rebuild.
    func testCompositionBuilderThreadsOverrideStoreIntoInstructions() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CanvasGesture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projectStore = try ProjectStore(rootURL: tempRoot)
        let project = try projectStore.create()
        try TestVideoFixtures.writeBlackMOV(
            to: project.screenURL, duration: t(1), withSilentAudio: true)
        try TestVideoFixtures.writeBlackMOV(
            to: project.cameraURL, duration: t(1))
        let screen = AVURLAsset(url: project.screenURL)
        let camera = AVURLAsset(url: project.cameraURL)
        let timeline = Timeline.fromAssets(screenAsset: screen, cameraAsset: camera)

        let store = PreviewOverrideStore()
        let output = try CompositionBuilder.build(
            timeline: timeline,
            screenAsset: screen,
            cameraAsset: camera,
            overrideStore: store)
        let instructions = output.videoComposition.instructions
        XCTAssertFalse(instructions.isEmpty)
        for raw in instructions {
            guard let i = raw as? BubbleCompositionInstruction else {
                return XCTFail("expected BubbleCompositionInstruction")
            }
            XCTAssertTrue(i.overrideStore === store)
            XCTAssertNotNil(i.screenClipID, "screen clip ID must be attached so the compositor can look up overrides")
        }
    }

    // MARK: - Gesture → EditStore flow

    private func makeTimeline() -> (Timeline, screenID: UUID, cameraID: UUID) {
        let screen = Clip(
            sourceID: .screen,
            sourceRange: range(0, duration: 10),
            timelineRange: range(0, duration: 10))
        let camera = Clip(
            sourceID: .camera,
            sourceRange: range(0, duration: 10),
            timelineRange: range(0, duration: 10))
        let tl = Timeline(
            tracks: [
                Track(kind: .video, sourceBinding: .screen, clips: [screen]),
                Track(kind: .video, sourceBinding: .camera, clips: [camera])
            ],
            duration: t(10))
        return (tl, screen.id, camera.id)
    }

    private func simulatePinch(on view: PreviewCanvasView,
                               phases: [(UIGestureRecognizer.State, CGFloat)]) {
        let recognizer = MockPinch()
        for (state, scale) in phases {
            recognizer.mockState = state
            recognizer.mockScale = scale
            view.perform(Selector(("handlePinch:")), with: recognizer)
        }
    }

    private func simulatePan(on view: PreviewCanvasView,
                             phases: [(UIGestureRecognizer.State, CGPoint)]) {
        let recognizer = MockPan(view: view)
        for (state, translation) in phases {
            recognizer.mockState = state
            recognizer.mockTranslation = translation
            view.perform(Selector(("handlePan:")), with: recognizer)
        }
    }

    /// Mid-drag pinch/pan writes MUST route through the override store, not
    /// the EditStore — otherwise the PlaybackController debounce fires a
    /// rebuild per tick and the undo stack is polluted with per-frame
    /// entries.
    func testMidGesturePinchDoesNotMutateTimeline() {
        let (tl, _, cameraID) = makeTimeline()
        let editStore = EditStore(timeline: tl)
        let view = PreviewCanvasView(frame: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        view.editStore = editStore
        view.selectedClipIDProvider = { cameraID }
        // No playback wired — override writes should be a no-op rather than
        // crash, and the edit store must stay untouched.

        let snapshot = editStore.timeline
        simulatePinch(on: view, phases: [
            (.began, 1.0),
            (.changed, 1.5),
            (.changed, 1.8)
        ])
        XCTAssertEqual(editStore.timeline, snapshot,
                       "mid-drag writes must not mutate the timeline")
    }

    /// Gesture end commits exactly one `EditStore.apply` — every tick along
    /// the way is written to the override store but undo must see the full
    /// drag as a single reversible step.
    func testGestureEndProducesExactlyOneUndoStep() {
        let (tl, _, cameraID) = makeTimeline()
        let editStore = EditStore(timeline: tl)
        let view = PreviewCanvasView(frame: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        view.editStore = editStore
        view.selectedClipIDProvider = { cameraID }

        XCTAssertFalse(editStore.canUndo)

        simulatePinch(on: view, phases: [
            (.began, 1.0),
            (.changed, 1.2),
            (.changed, 1.5),
            (.changed, 1.8),
            (.ended, 2.0)
        ])

        XCTAssertTrue(editStore.canUndo)
        XCTAssertEqual(editStore.timeline.tracks[1].clips[0].canvasScale, 2.0, accuracy: 1e-6)

        // One undo returns the timeline to its pre-drag state.
        editStore.undo()
        XCTAssertEqual(editStore.timeline.tracks[1].clips[0].canvasScale, 1.0, accuracy: 1e-6)
        XCTAssertFalse(editStore.canUndo,
                       "a single drag must register exactly one undo entry")
    }

    /// A no-op drag (finger down, finger up without motion) must NOT
    /// register an undo entry — otherwise accidental touches that the user
    /// didn't intend as edits land in the undo stack.
    func testNoOpGestureDoesNotRegisterUndo() {
        let (tl, _, cameraID) = makeTimeline()
        let editStore = EditStore(timeline: tl)
        let view = PreviewCanvasView(frame: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        view.editStore = editStore
        view.selectedClipIDProvider = { cameraID }

        simulatePinch(on: view, phases: [
            (.began, 1.0),
            (.ended, 1.0)
        ])
        XCTAssertFalse(editStore.canUndo)
    }

    /// A pan drag commits the translation in canvas pixels, mapped through
    /// the letterbox from the view-space delta the user's finger produced.
    /// The view is 540×1920 and renderSize is 1080×1920 → view:canvas 1:2.
    func testPanCommitTranslatesViewDeltaThroughLetterbox() {
        let (tl, screenID, _) = makeTimeline()
        let editStore = EditStore(timeline: tl)
        let view = PreviewCanvasView(frame: CGRect(x: 0, y: 0, width: 540, height: 1920))
        view.editStore = editStore
        view.selectedClipIDProvider = { screenID }
        view.testRenderSizeOverride = CGSize(width: 1080, height: 1920)

        simulatePan(on: view, phases: [
            (.began, .zero),
            (.changed, CGPoint(x: 20, y: 0)),
            (.ended, CGPoint(x: 20, y: 0))
        ])

        // fitScale = 0.5 → 20pt view → 40 canvas px
        let offset = editStore.timeline.tracks[0].clips[0].canvasOffset
        XCTAssertEqual(offset.x, 40, accuracy: 1e-6)
        XCTAssertEqual(offset.y, 0, accuracy: 1e-6)
    }
}

// MARK: - Test doubles

private final class MockPinch: UIPinchGestureRecognizer {
    var mockState: UIGestureRecognizer.State = .possible
    var mockScale: CGFloat = 1
    override var state: UIGestureRecognizer.State {
        get { mockState }
        set { mockState = newValue }
    }
    override var scale: CGFloat {
        get { mockScale }
        set { mockScale = newValue }
    }
    init() { super.init(target: nil, action: nil) }
}

private final class MockPan: UIPanGestureRecognizer {
    var mockState: UIGestureRecognizer.State = .possible
    var mockTranslation: CGPoint = .zero
    override var state: UIGestureRecognizer.State {
        get { mockState }
        set { mockState = newValue }
    }
    override func translation(in view: UIView?) -> CGPoint { mockTranslation }
    init(view: UIView) {
        super.init(target: nil, action: nil)
    }
}
