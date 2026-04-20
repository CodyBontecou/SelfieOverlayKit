import UIKit
import SwiftUI
import Combine

/// Internal controller that owns the camera session and the bubble view. The bubble
/// lives in a dedicated UIWindow at `.alert + 1` so it floats above modal sheets and
/// other host UI, while still being part of the scene's screen-capture composite.
final class OverlayController {

    let settingsStore = SettingsStore()

    /// Injected by `SelfieOverlayKit` so the inline config panel can drive recording.
    weak var recorder: RecordingController? {
        didSet { observeRecorder() }
    }
    private var recorderCancellable: AnyCancellable?

    /// Invoked when the user taps the close button in the bubble's action ring.
    /// The SDK wires this to its public `stop()` so `isVisible` stays in sync.
    var onTurnOffRequested: (() -> Void)?

    /// Forwarded from `SelfieOverlayKit.onRawExportComplete` so the controller
    /// can hand the bundle off to the host app after a raw export.
    var onRawExportComplete: ((RawExportBundle) -> Void)?

    /// Forwarded from `SelfieOverlayKit.onRawExportFailed`.
    var onRawExportFailed: ((SelfieOverlayError) -> Void)?

    private let cameraSession = CameraSession()
    private var overlayWindow: PassthroughWindow?
    private var bubble: BubbleView?
    private var panelHost: UIHostingController<BubbleConfigPanel>?
    private var panelDismissCatcher: DismissCatcherView?
    private var actionRingHost: UIHostingController<BubbleActionRing>?
    private var actionRingContainer: BubbleActionRingContainerView?
    private var actionRingState: BubbleActionRingState?
    private var actionRingDismissCatcher: DismissCatcherView?
    private var activeToast: ToastView?
    private var toastDismissWorkItem: DispatchWorkItem?
    private var wasRecording = false

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Show / hide

    func show() {
        guard bubble == nil else {
            cameraSession.start()
            bubble?.isHidden = false
            return
        }

        guard let scene = activeWindowScene() else { return }

        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let root = PassthroughRootViewController()
        window.rootViewController = root
        window.isHidden = false

        let bubble = BubbleView(cameraSession: cameraSession, settings: settingsStore)
        bubble.onTap = { [weak self] in
            self?.toggleActionRing()
        }
        bubble.onInteractionBegan = { [weak self] in
            self?.hideActionRing()
            self?.hideConfigPanel()
        }
        bubble.onStealthStopTap = { [weak self] in
            self?.stopRecordingFromStealth()
        }
        root.view.addSubview(bubble)

        self.bubble = bubble
        self.overlayWindow = window

        bubble.setRecordingIndicatorVisible(recorder?.isRecording == true)
        cameraSession.start()
    }

    private func observeRecorder() {
        recorderCancellable = recorder?.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self else { return }
                self.bubble?.setRecordingIndicatorVisible(isRecording)
                if isRecording {
                    if self.settingsStore.hideDuringRecording {
                        self.setStealthActive(true)
                    }
                } else {
                    self.setStealthActive(false)
                    if self.wasRecording {
                        self.showToast(message: "Recording saved", symbolName: "checkmark.circle.fill")
                    }
                }
                self.wasRecording = isRecording
            }
    }

    func hide() {
        hideActionRing(animated: false)
        hideConfigPanel()
        toastDismissWorkItem?.cancel()
        toastDismissWorkItem = nil
        activeToast?.removeFromSuperview()
        activeToast = nil
        cameraSession.stop()
        bubble?.removeFromSuperview()
        bubble = nil
        overlayWindow?.isHidden = true
        overlayWindow = nil
    }

    /// Snapshot of the pieces the recorder needs to capture the camera stream and
    /// bubble state alongside the screen recording. Returns nil if the bubble is
    /// not currently shown.
    func recordingContext() -> RecordingController.RecordingContext? {
        guard let bubble else { return nil }
        return RecordingController.RecordingContext(
            cameraSession: cameraSession,
            bubble: bubble,
            settings: settingsStore)
    }

    /// Temporarily hide the bubble without tearing down state (position, session, window).
    /// Used while the recording preview/edit screen is showing. Also restores the bubble
    /// to its normal (non-stealth) appearance while it's hidden, so that re-showing it
    /// after the editor is dismissed always brings back the full camera preview.
    func setBubbleHidden(_ hidden: Bool) {
        guard let overlayWindow else { return }
        if hidden {
            hideActionRing(animated: false)
            hideConfigPanel()
            bubble?.setStealthActive(false)
        }
        overlayWindow.isHidden = hidden
        if hidden {
            cameraSession.stop()
        } else {
            cameraSession.start()
        }
    }

    /// Swap the bubble for a tiny stop-recording affordance while recording, so the
    /// live camera preview is not visible on screen. The camera session and bubble
    /// state logger keep running, so the editor still gets the full selfie track.
    func setStealthActive(_ active: Bool) {
        guard let bubble else { return }
        if active {
            hideActionRing(animated: false)
            hideConfigPanel()
        }
        bubble.setStealthActive(active)
    }

    private func stopRecordingFromStealth() {
        guard let recorder, recorder.isRecording else { return }
        stopRecording(via: recorder)
    }

    /// Stops the recording and raw-exports the resulting bundle into a
    /// per-recording folder (see `nextRawExportDestination`), delivering the
    /// URLs to the host via `onRawExportComplete`. If the destination can't be
    /// resolved, or the pipeline errors, `onRawExportFailed` fires instead.
    private func stopRecording(via recorder: RecordingController) {
        guard let destination = nextRawExportDestination() else {
            DebugLog.log("pipeline", "raw export destination unavailable; dropping recording")
            onRawExportFailed?(.recordingUnavailable)
            recorder.stop(completion: nil)
            return
        }
        recorder.stopAndExportRaw(to: destination, demuxAudio: true) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let bundle):
                self.onRawExportComplete?(bundle)
            case .failure(let error):
                DebugLog.log("pipeline", "raw export failed: \(error.localizedDescription)")
                self.onRawExportFailed?(error)
            }
        }
    }

    /// `<root>/SelfieOverlayKit/RawExports/<uuid>/`, where `<root>` is either
    /// the Documents or Application Support directory depending on
    /// `settings.rawExportLocation`. The folder itself is created lazily by
    /// `RawExporter`; we just compute the path. Host apps own cleanup once
    /// the bundle has been delivered via `onRawExportComplete`.
    private func nextRawExportDestination() -> URL? {
        let fm = FileManager.default
        let directory: FileManager.SearchPathDirectory = {
            switch settingsStore.rawExportLocation {
            case .documents: return .documentDirectory
            case .applicationSupport: return .applicationSupportDirectory
            }
        }()
        guard let root = try? fm.url(
            for: directory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true) else { return nil }
        return root
            .appendingPathComponent("SelfieOverlayKit", isDirectory: true)
            .appendingPathComponent("RawExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: - Settings sheet

    func presentSettings(from presenter: UIViewController) {
        let view = SelfieOverlaySettingsView(settings: settingsStore)
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .formSheet
        presenter.present(host, animated: true)
    }

    // MARK: - Toast

    private func showToast(message: String, symbolName: String, duration: TimeInterval = 1.8) {
        guard let overlayWindow, let root = overlayWindow.rootViewController else { return }

        activeToast?.removeFromSuperview()
        toastDismissWorkItem?.cancel()

        let toast = ToastView(message: message, symbolName: symbolName)
        toast.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: root.view.centerXAnchor),
            toast.topAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])

        toast.alpha = 0
        toast.transform = CGAffineTransform(translationX: 0, y: -8)
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            toast.alpha = 1
            toast.transform = .identity
        }

        activeToast = toast

        let dismiss = DispatchWorkItem { [weak self, weak toast] in
            guard let toast else { return }
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn], animations: {
                toast.alpha = 0
                toast.transform = CGAffineTransform(translationX: 0, y: -8)
            }, completion: { _ in
                toast.removeFromSuperview()
                if self?.activeToast === toast { self?.activeToast = nil }
            })
        }
        toastDismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismiss)
    }

    // MARK: - Action ring

    func toggleActionRing() {
        if actionRingHost != nil {
            hideActionRing()
        } else {
            showActionRing()
        }
    }

    private func showActionRing() {
        guard actionRingHost == nil,
              let overlayWindow,
              let root = overlayWindow.rootViewController,
              let bubble else { return }

        // Dismiss the panel if it happened to be open via some other path.
        hideConfigPanel()

        // Put the icons on the opposite side of whichever screen edge the
        // bubble is closer to, so they stay fully on-screen.
        let placement: BubbleActionRing.Placement =
            bubble.center.x > root.view.bounds.midX ? .left : .right

        let state = BubbleActionRingState()
        let ring = BubbleActionRing(
            state: state,
            bubbleSize: bubble.bounds.width,
            placement: placement,
            onClose: { [weak self] in self?.handleTurnOff() },
            onEdit: { [weak self] in
                guard let self else { return }
                self.hideActionRing()
                self.showConfigPanel()
            }
        )
        let host = UIHostingController(rootView: ring)
        host.view.backgroundColor = .clear

        let catcher = DismissCatcherView(frame: root.view.bounds)
        catcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        catcher.bubble = bubble
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(handleActionRingDismissTap))
        catcher.addGestureRecognizer(dismissTap)
        root.view.addSubview(catcher)

        let side = BubbleActionRing.containerSize(bubbleSize: bubble.bounds.width)
        let container = BubbleActionRingContainerView(
            frame: CGRect(x: bubble.center.x - side / 2,
                          y: bubble.center.y - side / 2,
                          width: side,
                          height: side))
        container.iconCenters = BubbleActionRing.iconCenters(
            bubbleSize: bubble.bounds.width,
            placement: placement)
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(host.view)

        root.addChild(host)
        root.view.addSubview(container)
        host.didMove(toParent: root)

        actionRingHost = host
        actionRingContainer = container
        actionRingState = state
        actionRingDismissCatcher = catcher

        // Defer the visibility flip one runloop tick so SwiftUI can register the
        // initial (collapsed) state and animate the transition to visible.
        DispatchQueue.main.async {
            state.visible = true
        }
    }

    @objc private func handleActionRingDismissTap() {
        hideActionRing()
    }

    func hideActionRing(animated: Bool = true) {
        actionRingDismissCatcher?.removeFromSuperview()
        actionRingDismissCatcher = nil

        guard let host = actionRingHost,
              let container = actionRingContainer,
              let state = actionRingState else { return }
        actionRingHost = nil
        actionRingContainer = nil
        actionRingState = nil

        let cleanup = {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            container.removeFromSuperview()
        }

        if animated {
            state.visible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                cleanup()
            }
        } else {
            cleanup()
        }
    }

    // MARK: - Inline config panel

    func toggleConfigPanel() {
        if panelHost != nil {
            hideConfigPanel()
        } else {
            showConfigPanel()
        }
    }

    private func showConfigPanel() {
        guard panelHost == nil,
              let overlayWindow,
              let root = overlayWindow.rootViewController,
              let bubble,
              let recorder else { return }

        let catcher = DismissCatcherView(frame: root.view.bounds)
        catcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        catcher.bubble = bubble
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(handleDismissCatcherTap))
        catcher.addGestureRecognizer(dismissTap)
        root.view.addSubview(catcher)

        let panel = BubbleConfigPanel(
            settings: settingsStore,
            recorder: recorder,
            onToggleRecording: { [weak self] in self?.toggleRecording() },
            onClose: { [weak self] in self?.hideConfigPanel() }
        )
        let host = UIHostingController(rootView: panel)
        host.view.backgroundColor = .clear
        root.addChild(host)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)

        positionPanel(host, relativeTo: bubble, in: root.view)

        host.view.alpha = 0
        host.view.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.18) {
            host.view.alpha = 1
            host.view.transform = .identity
        }

        self.panelHost = host
        self.panelDismissCatcher = catcher
    }

    @objc private func handleDismissCatcherTap() {
        hideConfigPanel()
    }

    private func handleTurnOff() {
        hideConfigPanel()
        if let onTurnOffRequested {
            onTurnOffRequested()
        } else {
            hide()
        }
    }

    private func toggleRecording() {
        guard let recorder else { return }
        if recorder.isRecording {
            hideConfigPanel()
            stopRecording(via: recorder)
        } else {
            hideConfigPanel()
            recorder.start(withMicrophone: true, completion: nil)
        }
    }

    func hideConfigPanel() {
        panelDismissCatcher?.removeFromSuperview()
        panelDismissCatcher = nil
        guard let host = panelHost else { return }
        panelHost = nil
        UIView.animate(withDuration: 0.15, animations: {
            host.view.alpha = 0
            host.view.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        }, completion: { _ in
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        })
    }

    private func positionPanel(_ host: UIHostingController<BubbleConfigPanel>,
                               relativeTo bubble: UIView,
                               in container: UIView) {
        let targetWidth: CGFloat = 280
        let fitting = host.sizeThatFits(in: CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
        let width = max(fitting.width, targetWidth)
        let height = fitting.height
        let margin: CGFloat = 12
        let safe = container.safeAreaInsets

        let minX = safe.left + margin
        let maxX = container.bounds.width - safe.right - margin - width
        var x = bubble.center.x - width / 2
        x = max(minX, min(x, maxX))

        let below = bubble.frame.maxY + margin
        let above = bubble.frame.minY - margin - height
        let maxY = container.bounds.height - safe.bottom - margin - height
        let minY = safe.top + margin
        let y: CGFloat
        if below <= maxY {
            y = below
        } else if above >= minY {
            y = above
        } else {
            y = max(minY, min(bubble.center.y - height / 2, maxY))
        }

        host.view.frame = CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Lifecycle

    @objc private func appWillResignActive() {
        cameraSession.stop()
    }

    @objc private func appDidBecomeActive() {
        if bubble != nil {
            cameraSession.start()
        }
    }

    // MARK: - Helpers

    private func activeWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

/// Window that forwards touches outside its bubble content to the host app's windows.
/// Keeping the window at `.alert + 1` parks the bubble above modally-presented sheets.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // The root VC's view is our transparent canvas — if the user tapped it, the
        // tap was not on the bubble, so let it fall through to host windows below.
        if hit === rootViewController?.view { return nil }
        return hit
    }
}

/// Transparent full-screen view that catches taps outside the config panel to dismiss it.
/// Lets touches on the bubble fall through so the user can still drag or pinch it,
/// which the bubble translates into an `onInteractionBegan` dismiss.
final class DismissCatcherView: UIView {
    weak var bubble: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let bubble, bubble.frame.contains(point) { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Transparent root that does not assume status-bar/appearance ownership away from
/// the host app.
final class PassthroughRootViewController: UIViewController {
    override func loadView() {
        let v = UIView()
        v.backgroundColor = .clear
        view = v
    }
    override var childForStatusBarStyle: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }
    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }
}
