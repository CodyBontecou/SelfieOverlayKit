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
    private let summonGesture = SummonGestureController()

    public private(set) var isVisible: Bool = false

    private init() {
        recorder.setOverlayHidden = { [weak self] hidden in
            self?.controller.setBubbleHidden(hidden)
        }
        recorder.recordingContextProvider = { [weak self] in
            self?.controller.recordingContext()
        }
        controller.recorder = recorder
        controller.onTurnOffRequested = { [weak self] in
            self?.stop()
        }
    }

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

    // MARK: - Summon gesture

    /// Installs a global tap gesture on the host app's key window that toggles the
    /// bubble. Defaults to a triple-tap with two fingers. The gesture is observational
    /// (`cancelsTouchesInView = false`) so it does not interfere with the host UI.
    ///
    /// Call once at launch — e.g. from `SceneDelegate.scene(_:willConnectTo:options:)`
    /// or the SwiftUI `App`'s `init`.
    public func enableSummonGesture(taps: Int = 3, touches: Int = 2) {
        summonGesture.enable(taps: taps, touches: touches) { [weak self] in
            self?.toggle()
        }
    }

    public func disableSummonGesture() {
        summonGesture.disable()
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

    /// Stops recording, persists a project folder with the raw screen / camera
    /// tracks plus the bubble timeline, and presents the editor on top of
    /// `presenter`. The completion fires with the `EditorProject` backing the
    /// editor (or an error).
    public func stopRecording(presenter: UIViewController,
                              completion: ((Result<EditorProject, SelfieOverlayError>) -> Void)? = nil) {
        recorder.stopAndPresentEditor(from: presenter, completion: completion)
    }

    /// Stops recording and writes the raw tracks (screen.mov, camera.mov,
    /// optionally a demuxed audio.m4a, and bubble.json) into `destination`,
    /// skipping the in-app editor. Use this when the host app intends to do
    /// its own editing in an external NLE.
    ///
    /// `destination` must be a directory; it will be created if missing.
    /// Existing files at the four target paths are overwritten.
    ///
    /// When `demuxAudio` is true and the recording was started with the
    /// microphone, the mic audio is exported as a standalone `audio.m4a`
    /// alongside the embedded copy in `screen.mov`. When the recording was
    /// started without a microphone, `audioURL` in the bundle will be nil.
    public func stopRecording(exportTo destination: URL,
                              demuxAudio: Bool = true,
                              completion: ((Result<RawExportBundle, SelfieOverlayError>) -> Void)? = nil) {
        recorder.stopAndExportRaw(to: destination,
                                  demuxAudio: demuxAudio,
                                  completion: completion)
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
