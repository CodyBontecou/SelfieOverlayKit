import UIKit
import AVFoundation

/// Public entry point for the SDK. Host apps interact through `SelfieOverlayKit.shared`.
///
/// Host app requirements:
/// - Add `NSCameraUsageDescription` to Info.plist.
/// - Add `NSMicrophoneUsageDescription` to Info.plist if recording with audio.
public final class SelfieOverlayKit {

    public static let shared = SelfieOverlayKit()

    private let controller = OverlayController()
    private let recorder = RecordingController()

    public private(set) var isVisible: Bool = false

    private init() {}

    // MARK: - Visibility

    /// Request camera permission if needed, then show the overlay.
    /// Safe to call multiple times.
    public func start(completion: ((Result<Void, SelfieOverlayError>) -> Void)? = nil) {
        CameraAuthorization.request { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    completion?(.failure(.cameraPermissionDenied))
                    return
                }
                self.controller.show()
                self.isVisible = true
                completion?(.success(()))
            }
        }
    }

    public func stop() {
        controller.hide()
        isVisible = false
    }

    public func toggle(completion: ((Result<Void, SelfieOverlayError>) -> Void)? = nil) {
        if isVisible {
            stop()
            completion?(.success(()))
        } else {
            start(completion: completion)
        }
    }

    // MARK: - Settings

    /// Presents the built-in settings sheet so users can customize shape, mirror, opacity, etc.
    /// Wire this into the host app's settings screen to expose the overlay to end users.
    public func presentSettings(from presenter: UIViewController) {
        controller.presentSettings(from: presenter)
    }

    /// Read or mutate settings programmatically (for host apps that want their own UI).
    public var settings: SettingsStore { controller.settingsStore }

    // MARK: - Recording

    public var isRecording: Bool { recorder.isRecording }

    /// Begins ReplayKit in-app recording. Captures the full app surface including the overlay.
    public func startRecording(withMicrophone: Bool = true,
                               completion: ((Result<Void, SelfieOverlayError>) -> Void)? = nil) {
        recorder.start(withMicrophone: withMicrophone, completion: completion)
    }

    /// Stops recording and presents the system preview sheet for trim/save/share.
    public func stopRecording(presenter: UIViewController,
                              completion: ((Result<Void, SelfieOverlayError>) -> Void)? = nil) {
        recorder.stopAndPresentPreview(from: presenter, completion: completion)
    }
}

// MARK: - Errors

public enum SelfieOverlayError: Error, LocalizedError {
    case cameraPermissionDenied
    case microphonePermissionDenied
    case cameraUnavailable
    case recordingUnavailable
    case recordingAlreadyInProgress
    case recordingNotInProgress
    case underlying(Error)

    public var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied: return "Camera access was denied."
        case .microphonePermissionDenied: return "Microphone access was denied."
        case .cameraUnavailable: return "No front camera is available on this device."
        case .recordingUnavailable: return "Screen recording is not available on this device."
        case .recordingAlreadyInProgress: return "A recording is already in progress."
        case .recordingNotInProgress: return "No recording is in progress."
        case .underlying(let error): return error.localizedDescription
        }
    }
}
