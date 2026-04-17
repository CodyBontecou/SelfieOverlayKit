import UIKit
import AVFoundation
import Combine

/// The draggable, resizable camera bubble. Applies shape, mirror, border, and opacity
/// from `SettingsStore`, and persists position/size changes back to it.
final class BubbleView: UIView {

    private let previewView = CameraPreviewView()
    private let settings: SettingsStore
    private weak var session: AVCaptureSession?

    private var panStart: CGPoint = .zero
    private var pinchStartSize: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()

    /// Called when the user long-presses the bubble. Host app should present settings.
    var onRequestSettings: (() -> Void)?

    init(session: AVCaptureSession, settings: SettingsStore) {
        self.session = session
        self.settings = settings
        super.init(frame: CGRect(origin: settings.position,
                                 size: CGSize(width: settings.size, height: settings.size)))
        setupSubviews()
        applySettings(shape: settings.shape,
                      mirror: settings.mirror,
                      opacity: settings.opacity,
                      size: settings.size)
        observeSettings()
        attachGestures()
        accessibilityLabel = "Selfie camera"
        accessibilityHint = "Drag to move, pinch to resize, double-tap to change shape, long-press for settings."
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupSubviews() {
        layer.masksToBounds = true
        previewView.session = session
        previewView.frame = bounds
        previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(previewView)

        // Subtle drop shadow on a container layer (we can't shadow a masked layer).
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
    }

    private func observeSettings() {
        // @Published fires in willSet (before assignment). receive(on: RunLoop.main)
        // defers to the next runloop tick, at which point the store has been updated,
        // so reading settings.* returns the true current state.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyCurrentSettings() }
            .store(in: &cancellables)
    }

    private func applyCurrentSettings() {
        applySettings(shape: settings.shape,
                      mirror: settings.mirror,
                      opacity: settings.opacity,
                      size: settings.size)
    }

    // MARK: - Rendering

    private func applySettings(shape: BubbleShape,
                               mirror: Bool,
                               opacity: Double,
                               size: CGFloat) {
        alpha = CGFloat(opacity)

        // Size, keeping center stable.
        let centerBefore = center
        bounds = CGRect(origin: .zero, size: CGSize(width: size, height: size))
        center = centerBefore

        switch shape {
        case .circle:
            layer.cornerRadius = size / 2
        case .roundedRect:
            layer.cornerRadius = size * 0.18
        case .rect:
            layer.cornerRadius = 0
        }
        // Shadow path must match the rendered corner to render correctly with masking.
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath

        previewView.transform = mirror
            ? CGAffineTransform(scaleX: -1, y: 1)
            : .identity

        applyBorder(width: settings.borderWidth, hue: settings.borderHue)
    }

    private func applyBorder(width: CGFloat, hue: Double) {
        layer.borderWidth = width
        let color = UIColor(hue: CGFloat(hue),
                            saturation: 0.7,
                            brightness: 0.95,
                            alpha: 1.0)
        layer.borderColor = color.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewView.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    // MARK: - Gestures

    private func attachGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        addGestureRecognizer(longPress)
    }

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        guard let superview else { return }
        switch gr.state {
        case .began:
            panStart = center
        case .changed:
            let t = gr.translation(in: superview)
            center = clampedCenter(CGPoint(x: panStart.x + t.x, y: panStart.y + t.y),
                                   in: superview.bounds)
        case .ended, .cancelled:
            settings.position = frame.origin
            snapToEdgeIfNear(in: superview.bounds)
        default:
            break
        }
    }

    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        switch gr.state {
        case .began:
            pinchStartSize = settings.size
        case .changed:
            let proposed = pinchStartSize * gr.scale
            let clamped = max(80, min(proposed, 320))
            settings.size = clamped
        case .ended, .cancelled:
            if let superview {
                let clamped = clampedCenter(center, in: superview.bounds)
                center = clamped
                settings.position = frame.origin
            }
        default:
            break
        }
    }

    @objc private func handleDoubleTap() {
        let all = BubbleShape.allCases
        let idx = all.firstIndex(of: settings.shape) ?? 0
        settings.shape = all[(idx + 1) % all.count]
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred()
        onRequestSettings?()
    }

    // MARK: - Layout helpers

    private func clampedCenter(_ proposed: CGPoint, in rect: CGRect) -> CGPoint {
        let half = bounds.width / 2
        let minX = rect.minX + half
        let maxX = rect.maxX - half
        let minY = rect.minY + half + 20 // avoid status bar
        let maxY = rect.maxY - half - 20 // avoid home indicator
        return CGPoint(x: min(max(proposed.x, minX), maxX),
                       y: min(max(proposed.y, minY), maxY))
    }

    private func snapToEdgeIfNear(in rect: CGRect) {
        let margin: CGFloat = 16
        var target = center
        let distanceLeft = center.x - rect.minX
        let distanceRight = rect.maxX - center.x
        if min(distanceLeft, distanceRight) < bounds.width {
            target.x = distanceLeft < distanceRight
                ? rect.minX + bounds.width / 2 + margin
                : rect.maxX - bounds.width / 2 - margin
        }
        UIView.animate(withDuration: 0.25,
                       delay: 0,
                       usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0.5,
                       options: [.allowUserInteraction],
                       animations: { self.center = target },
                       completion: { _ in self.settings.position = self.frame.origin })
    }
}
