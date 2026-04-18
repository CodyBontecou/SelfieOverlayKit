import UIKit
import AVFoundation
import Combine

/// The draggable, resizable camera bubble. Applies shape, mirror, border, and opacity
/// from `SettingsStore`, and persists position/size changes back to it.
final class BubbleView: UIView {

    private let previewView = CameraPreviewView()
    private let recordingIndicator = RecordingIndicatorView()
    private let stealthStopView = StealthStopView()
    private let settings: SettingsStore
    private weak var cameraSession: CameraSession?

    private var panStart: CGPoint = .zero
    private var pinchStartSize: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()
    private(set) var stealthActive = false
    private var savedCornerRadius: CGFloat = 0
    private var savedBorderWidth: CGFloat = 0
    private var savedBorderColor: CGColor?
    private var savedBounds: CGRect = .zero

    /// Fixed side length of the stealth stop affordance. Kept small so a user with a
    /// large bubble doesn't suddenly get a big red disc covering their content.
    private static let stealthSize: CGFloat = 56

    /// Called when the user taps the bubble. Host controller toggles the radial action ring.
    /// Not fired while stealth recording is active — `onStealthStopTap` fires instead.
    var onTap: (() -> Void)?

    /// Called when the user starts a pan or pinch on the bubble, so the controller can
    /// dismiss any open affordance (action ring, config panel) before it drifts.
    var onInteractionBegan: (() -> Void)?

    /// Called when the user taps the bubble while it's in stealth-recording mode.
    /// Host controller uses this to stop recording and present the editor.
    var onStealthStopTap: (() -> Void)?

    init(cameraSession: CameraSession, settings: SettingsStore) {
        self.cameraSession = cameraSession
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
        accessibilityHint = "Drag to move, pinch to resize, tap to show settings."
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupSubviews() {
        layer.masksToBounds = true
        previewView.cameraSession = cameraSession
        previewView.frame = bounds
        previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(previewView)

        recordingIndicator.isHidden = true
        addSubview(recordingIndicator)

        stealthStopView.isHidden = true
        stealthStopView.frame = bounds
        stealthStopView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(stealthStopView)

        // Subtle drop shadow on a container layer (we can't shadow a masked layer).
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
    }

    /// Swap the camera preview for a small draggable stop-recording affordance. Used
    /// when the user enabled "Hide during recording" in settings — the selfie feed is
    /// still being captured to disk for the editor, but the live UI is suppressed.
    func setStealthActive(_ active: Bool) {
        guard stealthActive != active else { return }
        stealthActive = active
        if active {
            savedCornerRadius = layer.cornerRadius
            savedBorderWidth = layer.borderWidth
            savedBorderColor = layer.borderColor
            savedBounds = bounds
            previewView.isHidden = true
            recordingIndicator.isHidden = true
            stealthStopView.isHidden = false
            alpha = 1
            backgroundColor = .clear
            let side = Self.stealthSize
            let centerBefore = center
            bounds = CGRect(x: 0, y: 0, width: side, height: side)
            center = centerBefore
            layer.cornerRadius = side / 2
            layer.borderWidth = 0
            layer.borderColor = UIColor.clear.cgColor
            layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
            if let superview {
                center = clampedCenter(center, in: superview.bounds)
            }
        } else {
            previewView.isHidden = false
            stealthStopView.isHidden = true
            backgroundColor = nil
            let centerBefore = center
            bounds = savedBounds
            center = centerBefore
            layer.cornerRadius = savedCornerRadius
            layer.borderWidth = savedBorderWidth
            layer.borderColor = savedBorderColor
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
            if let superview {
                center = clampedCenter(center, in: superview.bounds)
            }
            applyCurrentSettings()
        }
    }

    /// Shows/hides the pulsing red recording indicator in the bubble's top-right
    /// corner. The indicator lives purely in the live UIView hierarchy and does
    /// not appear in exported videos — see `RecordingIndicatorView` for details.
    func setRecordingIndicatorVisible(_ visible: Bool) {
        recordingIndicator.setActive(visible)
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
        // While stealth-recording the bubble is a fixed stop affordance, so keep its
        // appearance locked. The saved shape/size is restored on `setStealthActive(false)`.
        guard !stealthActive else { return }
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
        stealthStopView.frame = bounds
        layoutRecordingIndicator()
        if stealthActive {
            layer.cornerRadius = bounds.width / 2
            layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
        } else {
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
        }
    }

    private func layoutRecordingIndicator() {
        // Scale the dot with the bubble but clamp so it stays legible and doesn't
        // dominate small bubbles. Inset from the top-right by roughly the corner
        // radius so it visually sits inside the rounded shape rather than on top
        // of the border.
        let dotSize = max(8, min(bounds.width * 0.09, 16))
        let cornerInset = max(6, layer.cornerRadius * 0.35)
        recordingIndicator.frame = CGRect(
            x: bounds.maxX - dotSize - cornerInset,
            y: bounds.minY + cornerInset,
            width: dotSize,
            height: dotSize)
    }

    // MARK: - Gestures

    private func attachGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        guard let superview else { return }
        switch gr.state {
        case .began:
            panStart = center
            onInteractionBegan?()
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
            onInteractionBegan?()
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

    @objc private func handleTap() {
        if stealthActive {
            onStealthStopTap?()
        } else {
            onTap?()
        }
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
