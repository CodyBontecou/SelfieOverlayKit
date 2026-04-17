import ReplayKit
import UIKit

/// Wraps `RPScreenRecorder` for in-app recording. Captures the app's rendered surface
/// (including the overlay window) and presents the system preview sheet on stop.
final class RecordingController: NSObject {

    private let recorder = RPScreenRecorder.shared()

    var isRecording: Bool { recorder.isRecording }

    func start(withMicrophone: Bool,
               completion: ((Result<Void, SelfieOverlayError>) -> Void)?) {
        guard recorder.isAvailable else {
            completion?(.failure(.recordingUnavailable))
            return
        }
        guard !recorder.isRecording else {
            completion?(.failure(.recordingAlreadyInProgress))
            return
        }

        recorder.isMicrophoneEnabled = withMicrophone
        recorder.startRecording { error in
            DispatchQueue.main.async {
                if let error {
                    completion?(.failure(.underlying(error)))
                } else {
                    completion?(.success(()))
                }
            }
        }
    }

    func stopAndPresentPreview(from presenter: UIViewController,
                               completion: ((Result<Void, SelfieOverlayError>) -> Void)?) {
        guard recorder.isRecording else {
            completion?(.failure(.recordingNotInProgress))
            return
        }

        recorder.stopRecording { [weak self] preview, error in
            DispatchQueue.main.async {
                if let error {
                    completion?(.failure(.underlying(error)))
                    return
                }
                guard let preview else {
                    completion?(.success(()))
                    return
                }
                preview.previewControllerDelegate = self
                preview.modalPresentationStyle = .formSheet
                presenter.present(preview, animated: true) {
                    completion?(.success(()))
                }
            }
        }
    }
}

extension RecordingController: RPPreviewViewControllerDelegate {
    func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
        previewController.dismiss(animated: true)
    }
}
