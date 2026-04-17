import UIKit
import SwiftUI

/// Internal controller that owns the camera session and the bubble view. The bubble
/// lives in a dedicated UIWindow at `.alert + 1` so it floats above modal sheets and
/// other host UI, while still being part of the scene's screen-capture composite.
final class OverlayController {

    let settingsStore = SettingsStore()

    private let cameraSession = CameraSession()
    private weak var hostWindow: UIWindow?
    private var overlayWindow: PassthroughWindow?
    private var bubble: BubbleView?

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

        let bubble = BubbleView(session: cameraSession.session, settings: settingsStore)
        bubble.onRequestSettings = { [weak self] in
            guard let self, let top = self.topViewController() else { return }
            self.presentSettings(from: top)
        }
        root.view.addSubview(bubble)

        self.bubble = bubble
        self.overlayWindow = window

        cameraSession.start()
    }

    func hide() {
        cameraSession.stop()
        bubble?.removeFromSuperview()
        bubble = nil
        overlayWindow?.isHidden = true
        overlayWindow = nil
        hostWindow = nil
    }

    // MARK: - Settings sheet

    func presentSettings(from presenter: UIViewController) {
        let view = SelfieOverlaySettingsView(settings: settingsStore)
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .formSheet
        presenter.present(host, animated: true)
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
