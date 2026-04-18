import ReplayKit
import UIKit
import Combine

/// Orchestrates the recording pipeline:
/// 1. `BubbleStateLogger` samples the bubble's frame + appearance over time.
/// 2. `RawRecorder` writes the screen video (+ optional mic) via ReplayKit
///    in-app capture, while `CameraVideoRecorder` writes the raw front-camera
///    feed to a separate `.mov`.
/// 3. On stop, `CameraCompositor` overlays the camera stream on top of the
///    screen video using the bubble timeline, preserving the screen audio, and
///    hands the resulting file to `ExportPreviewViewController`.
///
/// The camera is composited in post rather than relying on ReplayKit to
/// capture the overlay window — in-app capture misses secondary windows at
/// high `windowLevel`s, so burning the selfie in afterwards is the only way
/// to guarantee it appears in the exported video.
final class RecordingController: NSObject, ObservableObject {

    struct RecordingContext {
        let cameraSession: CameraSession
        let bubble: UIView
        let settings: SettingsStore
    }

    private let raw = RawRecorder()
    private let cameraRecorder = CameraVideoRecorder()
    private let bubbleLogger = BubbleStateLogger()

    @Published private(set) var isRecording = false
    private var videoStartAbsTime: TimeInterval?

    /// Injected by `SelfieOverlayKit` so the controller can hide the live bubble while
    /// the recorded video is being previewed/edited.
    var setOverlayHidden: ((Bool) -> Void)?

    /// Injected by `SelfieOverlayKit` to hand the controller the live camera session,
    /// bubble view, and settings store at recording start time.
    var recordingContextProvider: (() -> RecordingContext?)?

    // MARK: - Start

    func start(withMicrophone: Bool,
               completion: ((Result<Void, SelfieOverlayError>) -> Void)?) {
        guard !isRecording else {
            completion?(.failure(.recordingAlreadyInProgress))
            return
        }
        guard let context = recordingContextProvider?() else {
            completion?(.failure(.recordingUnavailable))
            return
        }

        DebugLog.log("pipeline", "start: mic=\(withMicrophone)")
        videoStartAbsTime = nil
        bubbleLogger.start(bubble: context.bubble, settings: context.settings)

        raw.onVideoStart = { [weak self] hostSeconds in
            self?.videoStartAbsTime = hostSeconds
        }

        cameraRecorder.start(cameraSession: context.cameraSession) { [weak self] camResult in
            guard let self else { return }
            switch camResult {
            case .failure(let error):
                _ = self.bubbleLogger.stop(videoStartAbsTime: nil)
                completion?(.failure(.underlying(error)))
            case .success:
                self.raw.start(withMicrophone: withMicrophone) { [weak self] rawResult in
                    guard let self else { return }
                    switch rawResult {
                    case .success:
                        self.setRecordingOnMain(true)
                        completion?(.success(()))
                    case .failure(let error):
                        _ = self.bubbleLogger.stop(videoStartAbsTime: nil)
                        self.cameraRecorder.stop { result in
                            if case .success(let url) = result {
                                try? FileManager.default.removeItem(at: url)
                            }
                        }
                        if let selfieErr = error as? SelfieOverlayError {
                            completion?(.failure(selfieErr))
                        } else {
                            completion?(.failure(.underlying(error)))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Stop + preview

    func stopAndPresentPreview(from presenter: UIViewController,
                               completion: ((Result<Void, SelfieOverlayError>) -> Void)?) {
        guard isRecording else {
            completion?(.failure(.recordingNotInProgress))
            return
        }

        let videoStart = videoStartAbsTime
        let bubbleTimeline = bubbleLogger.stop(videoStartAbsTime: videoStart)

        let hud = ProcessingHUDViewController()
        presenter.present(hud, animated: true)

        let screenScale = UIScreen.main.scale
        DebugLog.log("pipeline", "stop requested; bubble snapshots=\(bubbleTimeline.snapshots.count) scale=\(screenScale)")
        hud.setStatus("Finalizing recordings…")

        let stopStart = CACurrentMediaTime()
        raw.stop { [weak self] rawResult in
            let screenElapsed = CACurrentMediaTime() - stopStart
            DebugLog.log("pipeline", "raw.stop returned after \(String(format: "%.2f", screenElapsed))s: \(String(describing: rawResult))")
            guard let self else { return }
            let camStart = CACurrentMediaTime()
            self.cameraRecorder.stop { camResult in
                let camElapsed = CACurrentMediaTime() - camStart
                DebugLog.log("pipeline", "cameraRecorder.stop returned after \(String(format: "%.2f", camElapsed))s: \(String(describing: camResult))")
                switch (rawResult, camResult) {
                case (.failure(let error), _):
                    if case .success(let url) = camResult {
                        try? FileManager.default.removeItem(at: url)
                    }
                    DebugLog.log("pipeline", "raw.stop failed: \(error.localizedDescription)")
                    self.finishWithError(error, hud: hud, completion: completion)
                case (_, .failure(let error)):
                    if case .success(let url) = rawResult {
                        try? FileManager.default.removeItem(at: url)
                    }
                    DebugLog.log("pipeline", "cameraRecorder.stop failed: \(error.localizedDescription)")
                    self.finishWithError(error, hud: hud, completion: completion)
                case (.success(let rawURL), .success(let cameraURL)):
                    hud.setStatus("Processing…")
                    let compositor = CameraCompositor()
                    compositor.onStatus = { [weak hud] phase in
                        hud?.setStatus(phase)
                    }
                    compositor.onProgress = { [weak hud] progress in
                        let suffix = progress.estimatedTotalFrames.map { "/\($0)" } ?? ""
                        hud?.setStatus("Processing \(progress.framesProcessed)\(suffix) frames")
                    }
                    let inputs = CameraCompositor.Inputs(
                        screenURL: rawURL,
                        cameraURL: cameraURL,
                        bubbleTimeline: bubbleTimeline,
                        screenScale: screenScale)
                    let composeStart = CACurrentMediaTime()
                    compositor.composite(inputs) { [weak self] composeResult in
                        let composeElapsed = CACurrentMediaTime() - composeStart
                        DebugLog.log("pipeline", "composite returned after \(String(format: "%.2f", composeElapsed))s: \(String(describing: composeResult))")
                        try? FileManager.default.removeItem(at: rawURL)
                        try? FileManager.default.removeItem(at: cameraURL)
                        guard let self else { return }
                        switch composeResult {
                        case .failure(let error):
                            self.finishWithError(error, hud: hud, completion: completion)
                        case .success(let finalURL):
                            self.setRecordingOnMain(false)
                            hud.dismiss(animated: true) {
                                self.presentPreview(finalURL,
                                                    from: presenter,
                                                    completion: completion)
                            }
                        }
                    }
                }
            }
        }
    }

    private func presentPreview(_ url: URL,
                                from presenter: UIViewController,
                                completion: ((Result<Void, SelfieOverlayError>) -> Void)?) {
        let preview = ExportPreviewViewController(videoURL: url)
        preview.onDismiss = { [weak self] finishedURL in
            try? FileManager.default.removeItem(at: finishedURL)
            self?.setOverlayHidden?(false)
        }
        preview.modalPresentationStyle = .fullScreen
        setOverlayHidden?(true)
        presenter.present(preview, animated: true) {
            completion?(.success(()))
        }
    }

    private func finishWithError(_ error: Error,
                                 hud: UIViewController,
                                 completion: ((Result<Void, SelfieOverlayError>) -> Void)?) {
        setRecordingOnMain(false)
        hud.dismiss(animated: true) {
            if let selfieErr = error as? SelfieOverlayError {
                completion?(.failure(selfieErr))
            } else {
                completion?(.failure(.underlying(error)))
            }
        }
    }

    // MARK: - Helpers

    private func setRecordingOnMain(_ value: Bool) {
        if Thread.isMainThread {
            isRecording = value
        } else {
            DispatchQueue.main.async { self.isRecording = value }
        }
    }
}
