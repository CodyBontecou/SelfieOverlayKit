import UIKit
import SwiftUI

/// Internal controller that owns the camera session and the bubble view. The bubble
/// is attached directly to the host app's key UIWindow so that ReplayKit's screen
/// capture composite always includes it.
final class OverlayController {

    let settingsStore = SettingsStore()

    private let cameraSession = CameraSession()
    private weak var hostWindow: UIWindow?
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

        guard let window = keyWindow() else { return }

        let bubble = BubbleView(session: cameraSession.session, settings: settingsStore)
        bubble.onRequestSettings = { [weak self] in
            guard let self, let top = self.topViewController() else { return }
            self.presentSettings(from: top)
        }
        // Adding as a direct subview of the window keeps it above the host app's
        // rootViewController content and inside the recorded scene composite.
        window.addSubview(bubble)
        self.bubble = bubble
        self.hostWindow = window

        cameraSession.start()
    }

    func hide() {
        cameraSession.stop()
        bubble?.removeFromSuperview()
        bubble = nil
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

    private func keyWindow() -> UIWindow? {
        guard let scene = activeWindowScene() else { return nil }
        return scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    }

    private func topViewController() -> UIViewController? {
        var top = hostWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
