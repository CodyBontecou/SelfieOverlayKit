import UIKit
import SwiftUI

/// Internal controller that owns the camera session and the bubble view. The bubble
/// lives in a dedicated UIWindow at `.alert + 1` so it floats above modal sheets and
/// other host UI, while still being part of the scene's screen-capture composite.
final class OverlayController {

    let settingsStore = SettingsStore()

    /// Injected by `SelfieOverlayKit` so the inline config panel can drive recording.
    weak var recorder: RecordingController?

    private let cameraSession = CameraSession()
    private weak var hostWindow: UIWindow?
    private var overlayWindow: PassthroughWindow?
    private var bubble: BubbleView?
    private var panelHost: UIHostingController<BubbleConfigPanel>?
    private var panelDismissCatcher: DismissCatcherView?

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
        hostWindow = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first

        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let root = PassthroughRootViewController()
        window.rootViewController = root
        window.isHidden = false

        let bubble = BubbleView(cameraSession: cameraSession, settings: settingsStore)
        bubble.onRequestConfig = { [weak self] in
            self?.toggleConfigPanel()
        }
        bubble.onInteractionBegan = { [weak self] in
            self?.hideConfigPanel()
        }
        root.view.addSubview(bubble)

        self.bubble = bubble
        self.overlayWindow = window

        cameraSession.start()
    }

    func hide() {
        hideConfigPanel()
        cameraSession.stop()
        bubble?.removeFromSuperview()
        bubble = nil
        overlayWindow?.isHidden = true
        overlayWindow = nil
        hostWindow = nil
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
    /// Used while the recording preview/edit screen is showing.
    func setBubbleHidden(_ hidden: Bool) {
        guard let overlayWindow else { return }
        if hidden { hideConfigPanel() }
        overlayWindow.isHidden = hidden
        if hidden {
            cameraSession.stop()
        } else {
            cameraSession.start()
        }
    }

    // MARK: - Settings sheet

    func presentSettings(from presenter: UIViewController) {
        let view = SelfieOverlaySettingsView(settings: settingsStore)
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .formSheet
        presenter.present(host, animated: true)
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

    private func toggleRecording() {
        guard let recorder else { return }
        if recorder.isRecording {
            guard let top = topViewController() else { return }
            hideConfigPanel()
            recorder.stopAndPresentPreview(from: top, completion: nil)
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

    private func topViewController() -> UIViewController? {
        var top = hostWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
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
