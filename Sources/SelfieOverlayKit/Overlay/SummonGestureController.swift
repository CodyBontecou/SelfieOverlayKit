import UIKit

/// Installs a multi-tap / multi-finger gesture recognizer on the host app's key window
/// and invokes `onTrigger` when the gesture fires. `cancelsTouchesInView` is `false`
/// so the recognizer is observational and does not swallow touches from the host UI.
///
/// Re-attaches on scene activation and key-window changes so the gesture survives
/// scene transitions, sheet presentations that promote new windows, etc.
final class SummonGestureController {

    private var taps: Int = 3
    private var touches: Int = 2
    private var onTrigger: (() -> Void)?
    private weak var attachedWindow: UIWindow?
    private var recognizer: UITapGestureRecognizer?
    private var isEnabled = false

    func enable(taps: Int, touches: Int, onTrigger: @escaping () -> Void) {
        self.taps = max(1, taps)
        self.touches = max(1, touches)
        self.onTrigger = onTrigger
        guard !isEnabled else {
            attachToKeyWindow()
            return
        }
        isEnabled = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(reattach),
            name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reattach),
            name: UIWindow.didBecomeKeyNotification, object: nil)
        attachToKeyWindow()
    }

    func disable() {
        isEnabled = false
        NotificationCenter.default.removeObserver(self)
        detach()
        onTrigger = nil
    }

    @objc private func reattach() {
        guard isEnabled else { return }
        attachToKeyWindow()
    }

    private func attachToKeyWindow() {
        guard let window = hostKeyWindow() else { return }
        if window === attachedWindow, recognizer != nil { return }
        detach()
        let rec = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        rec.numberOfTapsRequired = taps
        rec.numberOfTouchesRequired = touches
        rec.cancelsTouchesInView = false
        rec.delaysTouchesBegan = false
        rec.delaysTouchesEnded = false
        window.addGestureRecognizer(rec)
        recognizer = rec
        attachedWindow = window
    }

    private func detach() {
        if let rec = recognizer, let win = attachedWindow {
            win.removeGestureRecognizer(rec)
        }
        recognizer = nil
        attachedWindow = nil
    }

    @objc private func handleTap() {
        onTrigger?()
    }

    /// The foreground-active scene's key window, excluding our own overlay window so
    /// we never attach the summon gesture to a window that only exists while the
    /// bubble is visible.
    private func hostKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let scene else { return nil }
        let candidates = scene.windows.filter { !($0 is PassthroughWindow) }
        return candidates.first(where: { $0.isKeyWindow }) ?? candidates.first
    }
}
