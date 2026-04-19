import AVFoundation
import CoreMedia
import UIKit

/// `AVPlayerLayer` host that also handles direct manipulation of the selected
/// clip — pinch to scale, pan to move, tap to pick which layer (camera
/// bubble vs. screen) is active. Mid-gesture writes go through the
/// `PlaybackController.overrideStore` side channel so the `AVPlayerItem` is
/// never rebuilt during a drag; the final value lands in `EditStore` on
/// gesture end so there's exactly one undo entry per gesture.
final class PreviewCanvasView: UIView {

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspect
        }
    }

    // MARK: - Wiring from the editor

    /// Writers consult `EditStore` on gesture end to commit a single undoable
    /// mutation. `weak` so the view doesn't extend the edit store's lifetime.
    weak var editStore: EditStore?
    weak var playback: PlaybackController?

    /// Recording-time bubble snapshots. Used by the tap hit-test to know
    /// where the camera bubble is laid out *before* the user's per-clip
    /// transform is applied. `nil` means screen-only recording — tap falls
    /// back to selecting the screen clip.
    var bubbleTimeline: BubbleTimeline?

    /// Points→pixels factor used when projecting `state.frame` into canvas
    /// output pixels. Matches the value the compositor was built with.
    var screenScale: CGFloat = 1

    /// Returns the clip currently highlighted in the timeline, if any. The
    /// selection is owned by `TimelineView`; this view reads it so gestures
    /// know which clip they're manipulating and so the selection outline
    /// can track changes driven by the timeline UI.
    var selectedClipIDProvider: () -> UUID? = { nil }

    /// Fires when a tap on the preview switches the active clip. Plumbed
    /// back into `TimelineView.setSelectedClipID` + inspector update in the
    /// editor so the selection state stays consistent with the timeline.
    var onClipSelected: ((UUID?) -> Void)?

    /// Called on every selection-outline change so the editor can refresh
    /// after layout (e.g. after bounds change), not just after gesture end.
    private var lastRenderedSelectionRect: CGRect = .zero

    // MARK: - Selection outline

    /// Dashed rect drawn on top of the video showing the active layer's
    /// on-canvas footprint. Thin and subtle — it's an affordance, not a
    /// selection handle grid (that can come later if needed).
    private let selectionOutline: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = UIColor.clear.cgColor
        l.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85).cgColor
        l.lineWidth = 1.5
        l.lineDashPattern = [6, 4]
        l.isHidden = true
        return l
    }()

    // MARK: - Gesture state

    /// Snapshot of the clip's baked transform at the start of a drag
    /// session. Gesture-change handlers apply their deltas on top of this
    /// and push the result into `PreviewOverrideStore`; on release the same
    /// value is handed to `EditStore.apply` so the undo step covers the
    /// full drag, not every tick.
    private struct GestureSession {
        let clipID: UUID
        var base: BubbleOverlayRenderer.LayerTransform
        // Folded in as each recognizer ends, so a subsequent recognizer in
        // the same session picks up where the previous one left off.
        var scaleFactor: CGFloat = 1
        var offsetDelta: CGPoint = .zero
        // Gestures that are currently .began or .changed. The session ends
        // (one undo step committed) when this drops back to zero.
        var activeRecognizers: Int = 0

        func currentTransform() -> BubbleOverlayRenderer.LayerTransform {
            BubbleOverlayRenderer.LayerTransform(
                cropRect: base.cropRect,
                scale: base.scale * scaleFactor,
                offset: CGPoint(x: base.offset.x + offsetDelta.x,
                                y: base.offset.y + offsetDelta.y))
        }
    }

    private var session: GestureSession?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(selectionOutline)
        installGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        selectionOutline.frame = bounds
        updateSelectionOutline()
    }

    // `UIView.gestureRecognizerShouldBegin(_:)` is a UIKit override point —
    // declaring it here (not in the UIGestureRecognizerDelegate extension)
    // keeps us clear of the override-keyword conflict while still gating
    // pinch/pan when no clip is selected. Tap is always allowed so users
    // can select a layer on the canvas without first touching the timeline.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer { return true }
        return selectedClipIDProvider() != nil
    }

    // MARK: - Public surface

    /// Refreshes the selection outline after the timeline or selection
    /// changes upstream. Cheap enough to call unconditionally from the
    /// editor's timeline binding.
    func refreshSelection() {
        updateSelectionOutline()
    }

    // MARK: - Gesture setup

    private func installGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    // MARK: - Pinch

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginSessionIfNeeded()
        case .changed:
            guard var s = session else { return }
            s.scaleFactor = clampScaleFactor(gesture.scale, base: s.base.scale)
            session = s
            pushOverride()
        case .ended, .cancelled, .failed:
            guard var s = session else { return }
            s.base = BubbleOverlayRenderer.LayerTransform(
                cropRect: s.base.cropRect,
                scale: clampScale(s.base.scale * s.scaleFactor),
                offset: s.base.offset)
            s.scaleFactor = 1
            session = s
            endRecognizer()
        default:
            break
        }
    }

    private func clampScaleFactor(_ factor: CGFloat, base: CGFloat) -> CGFloat {
        // Clamp the *absolute* scale to the timeline's allowed range so we
        // don't let a mid-drag override show a value that would be snapped
        // back on commit.
        let target = base * factor
        let clamped = min(max(target, Timeline.canvasScaleRange.lowerBound),
                          Timeline.canvasScaleRange.upperBound)
        return clamped / max(base, 0.0001)
    }

    private func clampScale(_ value: CGFloat) -> CGFloat {
        min(max(value, Timeline.canvasScaleRange.lowerBound),
            Timeline.canvasScaleRange.upperBound)
    }

    // MARK: - Pan

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginSessionIfNeeded()
        case .changed:
            guard session != nil else { return }
            let viewTranslation = gesture.translation(in: self)
            let canvasDelta = Self.viewDeltaToCanvas(
                viewTranslation,
                viewSize: bounds.size,
                renderSize: currentRenderSize())
            var s = session!
            s.offsetDelta = canvasDelta
            session = s
            pushOverride()
        case .ended, .cancelled, .failed:
            guard var s = session else { return }
            let viewTranslation = gesture.translation(in: self)
            let canvasDelta = Self.viewDeltaToCanvas(
                viewTranslation,
                viewSize: bounds.size,
                renderSize: currentRenderSize())
            s.base = BubbleOverlayRenderer.LayerTransform(
                cropRect: s.base.cropRect,
                scale: s.base.scale,
                offset: CGPoint(x: s.base.offset.x + canvasDelta.x,
                                y: s.base.offset.y + canvasDelta.y))
            s.offsetDelta = .zero
            session = s
            endRecognizer()
        default:
            break
        }
    }

    // MARK: - Tap

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        let renderSize = currentRenderSize()
        guard renderSize.width > 0, renderSize.height > 0 else { return }
        guard let canvasPoint = Self.viewPointToCanvas(
            point, viewSize: bounds.size, renderSize: renderSize) else { return }

        let (screenClip, cameraClip) = activeClips()
        let cameraHit = cameraBubbleContains(canvasPoint, cameraClip: cameraClip)

        let currentID = selectedClipIDProvider()
        let newID: UUID?
        if cameraHit, let cameraID = cameraClip?.id {
            newID = cameraID
        } else if let screenID = screenClip?.id {
            // If the tap fell on a fullscreen camera we already selected it
            // above. Otherwise select the screen layer. If the screen is
            // already selected, leave it alone to avoid spamming the
            // timeline callback on every stray tap.
            newID = (currentID == screenID) ? currentID : screenID
        } else {
            newID = currentID
        }

        if newID != currentID {
            onClipSelected?(newID)
        }
    }

    // MARK: - Session lifecycle

    private func beginSessionIfNeeded() {
        if var s = session {
            s.activeRecognizers += 1
            session = s
            return
        }
        guard let clipID = selectedClipIDProvider(),
              let editStore,
              let clip = clip(for: clipID, in: editStore.timeline) else {
            return
        }
        session = GestureSession(
            clipID: clipID,
            base: transform(from: clip),
            activeRecognizers: 1)
    }

    private func endRecognizer() {
        guard var s = session else { return }
        s.activeRecognizers -= 1
        session = s
        if s.activeRecognizers <= 0 {
            commitSession(s)
        }
    }

    private func commitSession(_ s: GestureSession) {
        defer {
            // Clear the override *after* committing to the EditStore so the
            // frame rendered from the rebuilt composition is never shown
            // with an identity-reset bubble that jumps back to base.
            playback?.overrideStore.set(nil, forClip: s.clipID)
            session = nil
            playback?.refreshCurrentFrame()
            updateSelectionOutline()
        }
        let final = BubbleOverlayRenderer.LayerTransform(
            cropRect: s.base.cropRect,
            scale: clampScale(s.base.scale),
            offset: s.base.offset)
        guard let editStore,
              let clip = clip(for: s.clipID, in: editStore.timeline) else { return }
        let baked = transform(from: clip)
        guard final != baked else { return }

        // Bundle scale + offset + crop into a single named apply so the user
        // gets exactly one undo entry for the full drag. Apply only the
        // fields that actually changed so unrelated mutations don't get
        // pulled into the step.
        let clipID = s.clipID
        let newScale = final.scale
        let newOffset = final.offset
        let scaleChanged = abs(final.scale - baked.scale) > 1e-6
        let offsetChanged = final.offset != baked.offset
        editStore.apply(name: undoName(scaleChanged: scaleChanged, offsetChanged: offsetChanged)) {
            var tl = $0
            if scaleChanged { tl = tl.settingCanvasScale(clipID: clipID, newScale) }
            if offsetChanged { tl = tl.settingCanvasOffset(clipID: clipID, newOffset) }
            return tl
        }
    }

    private func undoName(scaleChanged: Bool, offsetChanged: Bool) -> String {
        switch (scaleChanged, offsetChanged) {
        case (true, true): return "Transform"
        case (true, false): return "Zoom"
        case (false, true): return "Move"
        default: return "Transform"
        }
    }

    private func pushOverride() {
        guard let s = session, let playback else { return }
        playback.overrideStore.set(s.currentTransform(), forClip: s.clipID)
        playback.refreshCurrentFrame()
        updateSelectionOutline()
    }

    // MARK: - Selection outline

    private func updateSelectionOutline() {
        guard let clipID = selectedClipIDProvider(),
              let editStore,
              let clip = clip(for: clipID, in: editStore.timeline) else {
            selectionOutline.isHidden = true
            return
        }
        let renderSize = currentRenderSize()
        guard renderSize.width > 0, renderSize.height > 0 else {
            selectionOutline.isHidden = true
            return
        }
        let transform = session?.currentTransform() ?? self.transform(from: clip)
        let canvasRect: CGRect
        switch clip.sourceID {
        case .screen:
            canvasRect = screenPlacedRect(
                transform: transform, renderSize: renderSize)
        case .camera:
            canvasRect = cameraPlacedRect(
                transform: transform, clip: clip, renderSize: renderSize)
        case .mic:
            selectionOutline.isHidden = true
            return
        }
        let viewRect = Self.canvasRectToView(
            canvasRect, viewSize: bounds.size, renderSize: renderSize)
        selectionOutline.frame = bounds
        selectionOutline.path = UIBezierPath(rect: viewRect).cgPath
        selectionOutline.isHidden = false
        lastRenderedSelectionRect = viewRect
    }

    // MARK: - Layer geometry

    private func screenPlacedRect(
        transform: BubbleOverlayRenderer.LayerTransform,
        renderSize: CGSize
    ) -> CGRect {
        Self.placedRect(
            natural: CGRect(origin: .zero, size: renderSize),
            transform: transform)
    }

    private func cameraPlacedRect(
        transform: BubbleOverlayRenderer.LayerTransform,
        clip: Clip,
        renderSize: CGSize
    ) -> CGRect {
        let natural = cameraNaturalRect(
            clip: clip, renderSize: renderSize)
        return Self.placedRect(natural: natural, transform: transform)
    }

    /// Replicates `BubbleOverlayRenderer.makeBubbleImage`'s natural rect
    /// math in UIKit coordinates (origin top-left). The renderer's version
    /// operates in CI space (origin bottom-left); we produce the same rect
    /// flipped to UIKit-top-left so selection outlines and hit tests line
    /// up with the user's visual expectations.
    private func cameraNaturalRect(clip: Clip, renderSize: CGSize) -> CGRect {
        if clip.cameraShape == .fullscreen {
            return CGRect(origin: .zero, size: renderSize)
        }
        guard let snapshot = currentBubbleSnapshot() else {
            return CGRect(origin: .zero, size: renderSize)
        }
        let widthPx = snapshot.frame.width * screenScale
        let heightPx = snapshot.frame.height * screenScale
        let x = snapshot.frame.origin.x * screenScale
        let y = snapshot.frame.origin.y * screenScale
        return CGRect(x: x, y: y, width: widthPx, height: heightPx)
    }

    private func currentBubbleSnapshot() -> BubbleTimeline.Snapshot? {
        guard let bubbleTimeline,
              let editStore,
              let playback else { return nil }
        let compTime = playback.player.currentTime()
        // Find the screen clip whose timelineRange contains the current
        // composition time; derive the source time from its mapping. The
        // bubble timeline is indexed by the screen source's time so this
        // matches what the compositor asks for at render time.
        for track in editStore.timeline.tracks where track.kind == .video && track.sourceBinding == .screen {
            if let clip = track.clips.first(where: {
                compTime >= $0.timelineRange.start && compTime < $0.timelineRange.end
            }) {
                let local = compTime - clip.timelineRange.start
                let sourceTime = clip.sourceRange.start +
                    CMTimeMultiplyByFloat64(local, multiplier: clip.speed)
                return bubbleTimeline.sample(at: sourceTime.seconds)
            }
        }
        return bubbleTimeline.sample(at: compTime.seconds)
    }

    // MARK: - Helpers

    private func activeClips() -> (screen: Clip?, camera: Clip?) {
        guard let editStore, let playback else { return (nil, nil) }
        let t = playback.player.currentTime()
        var screen: Clip?
        var camera: Clip?
        for track in editStore.timeline.tracks where track.kind == .video {
            let hit = track.clips.first { clip in
                t >= clip.timelineRange.start && t < clip.timelineRange.end
            } ?? track.clips.first
            switch track.sourceBinding {
            case .screen: screen = hit
            case .camera: camera = hit
            default: break
            }
        }
        return (screen, camera)
    }

    private func cameraBubbleContains(
        _ canvasPoint: CGPoint,
        cameraClip: Clip?
    ) -> Bool {
        guard let cameraClip else { return false }
        let renderSize = currentRenderSize()
        guard renderSize.width > 0, renderSize.height > 0 else { return false }
        let transform = transform(from: cameraClip)
        let rect = cameraPlacedRect(
            transform: transform, clip: cameraClip, renderSize: renderSize)
        return rect.contains(canvasPoint)
    }

    private func transform(from clip: Clip) -> BubbleOverlayRenderer.LayerTransform {
        BubbleOverlayRenderer.LayerTransform(
            cropRect: clip.cropRect,
            scale: clip.canvasScale,
            offset: clip.canvasOffset)
    }

    private func clip(for id: UUID, in timeline: Timeline) -> Clip? {
        guard let loc = timeline.locate(clipID: id) else { return nil }
        return timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
    }

    private func currentRenderSize() -> CGSize {
        let presentation = player?.currentItem?.presentationSize ?? .zero
        if presentation.width > 0, presentation.height > 0 { return presentation }
        // Before the player item reports a presentation size (first frame
        // hasn't rendered yet), fall back to the video composition's render
        // size — that's what the compositor was configured with.
        return player?.currentItem?.videoComposition?.renderSize ?? .zero
    }

    // MARK: - Coordinate math (static so tests can call directly)

    /// Compute the on-canvas placement of a layer given its `natural` rect
    /// (identity placement) and a `LayerTransform`. Returned in the same
    /// coordinate space as `natural` — UIKit-top-left for hit tests and the
    /// selection outline; CI-bottom-left when called by the renderer. The
    /// math is identical; only Y-axis orientation differs, and it's the
    /// caller's job to pick the right space.
    static func placedRect(
        natural: CGRect,
        transform: BubbleOverlayRenderer.LayerTransform
    ) -> CGRect {
        let w = natural.width * transform.scale
        let h = natural.height * transform.scale
        let x = natural.midX - w / 2 + transform.offset.x
        let y = natural.midY - h / 2 + transform.offset.y
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Translate a view-space delta (points, origin top-left) into a canvas
    /// delta (output pixels, origin top-left). Exposed for tests — the
    /// pinch/pan handlers must map touch deltas through the `.resizeAspect`
    /// letterbox to keep the layer tracking the user's finger 1:1.
    static func viewDeltaToCanvas(
        _ viewDelta: CGPoint,
        viewSize: CGSize,
        renderSize: CGSize
    ) -> CGPoint {
        guard let scale = fitScale(viewSize: viewSize, renderSize: renderSize) else {
            return .zero
        }
        return CGPoint(x: viewDelta.x / scale, y: viewDelta.y / scale)
    }

    /// Translate a view-space point into canvas coords, accounting for the
    /// letterbox margins. Returns `nil` when the point falls outside the
    /// video's on-screen rect (so callers can treat it as "not on the
    /// preview").
    static func viewPointToCanvas(
        _ point: CGPoint,
        viewSize: CGSize,
        renderSize: CGSize
    ) -> CGPoint? {
        guard let scale = fitScale(viewSize: viewSize, renderSize: renderSize) else {
            return nil
        }
        let displayedW = renderSize.width * scale
        let displayedH = renderSize.height * scale
        let insetX = (viewSize.width - displayedW) / 2
        let insetY = (viewSize.height - displayedH) / 2
        let localX = (point.x - insetX) / scale
        let localY = (point.y - insetY) / scale
        guard localX >= 0, localX <= renderSize.width,
              localY >= 0, localY <= renderSize.height else {
            return nil
        }
        return CGPoint(x: localX, y: localY)
    }

    /// Project a canvas-space rect (output pixels, origin top-left) back
    /// into view-space, used to draw the selection outline over the
    /// letterboxed video.
    static func canvasRectToView(
        _ canvasRect: CGRect,
        viewSize: CGSize,
        renderSize: CGSize
    ) -> CGRect {
        guard let scale = fitScale(viewSize: viewSize, renderSize: renderSize) else {
            return .zero
        }
        let insetX = (viewSize.width - renderSize.width * scale) / 2
        let insetY = (viewSize.height - renderSize.height * scale) / 2
        return CGRect(
            x: insetX + canvasRect.origin.x * scale,
            y: insetY + canvasRect.origin.y * scale,
            width: canvasRect.size.width * scale,
            height: canvasRect.size.height * scale)
    }

    private static func fitScale(viewSize: CGSize, renderSize: CGSize) -> CGFloat? {
        guard viewSize.width > 0, viewSize.height > 0,
              renderSize.width > 0, renderSize.height > 0 else {
            return nil
        }
        return min(viewSize.width / renderSize.width,
                   viewSize.height / renderSize.height)
    }
}

extension PreviewCanvasView: UIGestureRecognizerDelegate {
    // Allow pinch + pan to run simultaneously — two-finger manipulation
    // (CapCut-style) feels broken if the user has to lift their fingers to
    // switch between scale and translate.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        let a = gestureRecognizer
        let b = other
        if a is UITapGestureRecognizer || b is UITapGestureRecognizer {
            return false
        }
        return true
    }

}
