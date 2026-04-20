import CoreMedia
import ReplayKit
import UIKit
import Combine

/// Orchestrates the recording pipeline:
/// 1. `BubbleStateLogger` samples the bubble's frame + appearance over time.
/// 2. `RawRecorder` writes the screen video (+ optional mic) via ReplayKit
///    in-app capture, while `CameraVideoRecorder` writes the raw front-camera
///    feed to a separate `.mov`.
/// 3. On stop, both raw `.mov`s and the sampled `BubbleTimeline` are moved
///    into a per-recording session folder via `RecordingStore`, and the
///    caller is expected to copy them out via `RawExporter.export` (the only
///    public egress path).
///
/// The camera is kept as a separate track rather than relying on ReplayKit to
/// capture the overlay window — in-app capture misses secondary windows at
/// high `windowLevel`s, so the selfie is delivered as its own file for
/// downstream editing to composite.
final class RecordingController: NSObject, ObservableObject {

    struct RecordingContext {
        let cameraSession: CameraSession
        let bubble: BubbleView
        let settings: SettingsStore
    }

    private let raw = RawRecorder()
    private let cameraRecorder = CameraVideoRecorder()
    private let bubbleLogger = BubbleStateLogger()
    private let store: RecordingStore

    @Published private(set) var isRecording = false
    private var videoStartAbsTime: TimeInterval?

    override init() {
        do {
            self.store = try RecordingStore()
        } catch {
            fatalError("Unable to create RecordingStore: \(error)")
        }
        super.init()
    }

    init(store: RecordingStore) {
        self.store = store
        super.init()
    }

    /// Injected by `SelfieOverlayKit` so the controller can hide the live bubble while
    /// the recorded video is being handed back to the host app.
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
            guard let self else { return }
            self.videoStartAbsTime = hostSeconds
            // Camera listener was attached before ReplayKit started delivering
            // — anchor its writer here so the camera .mov begins at the same
            // wall-clock moment as the screen .mov rather than 2-3s earlier.
            let anchor = CMTime(seconds: hostSeconds, preferredTimescale: 600)
            self.cameraRecorder.anchorSession(atSourceTime: anchor)
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

    // MARK: - Stop

    /// Stops recording and exports the raw screen / camera / mic / bubble
    /// timeline files into `destination`, handing a `RawExportBundle` back to
    /// the caller.
    func stopAndExportRaw(to destination: URL,
                          demuxAudio: Bool,
                          completion: ((Result<RawExportBundle, SelfieOverlayError>) -> Void)?) {
        stop { result in
            switch result {
            case .failure(let error):
                completion?(.failure(error))
            case .success(let session):
                RawExporter.export(session: session,
                                   to: destination,
                                   demuxAudio: demuxAudio) { exportResult in
                    DispatchQueue.main.async {
                        switch exportResult {
                        case .success(let bundle):
                            completion?(.success(bundle))
                        case .failure(let error):
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
    }

    /// Stops the recorders and moves the raw screen / camera `.mov`s plus the
    /// sampled `BubbleTimeline` into a new session folder. The folder lives
    /// under Application Support and is owned by the SDK — callers should
    /// copy tracks out via `RawExporter`, not reach into the session URL.
    func stop(completion: ((Result<RecordedSession, SelfieOverlayError>) -> Void)?) {
        guard isRecording else {
            completion?(.failure(.recordingNotInProgress))
            return
        }

        let videoStart = videoStartAbsTime
        let bubbleTimeline = bubbleLogger.stop(videoStartAbsTime: videoStart)

        DebugLog.log("pipeline", "stop requested; bubble snapshots=\(bubbleTimeline.snapshots.count)")

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
                    self.finishWithError(error, completion: completion)
                case (_, .failure(let error)):
                    if case .success(let url) = rawResult {
                        try? FileManager.default.removeItem(at: url)
                    }
                    DebugLog.log("pipeline", "cameraRecorder.stop failed: \(error.localizedDescription)")
                    self.finishWithError(error, completion: completion)
                case (.success(let rawURL), .success(let cameraURL)):
                    self.persistSession(rawURL: rawURL,
                                        cameraURL: cameraURL,
                                        bubbleTimeline: bubbleTimeline,
                                        completion: completion)
                }
            }
        }
    }

    private func persistSession(rawURL: URL,
                                cameraURL: URL,
                                bubbleTimeline: BubbleTimeline,
                                completion: ((Result<RecordedSession, SelfieOverlayError>) -> Void)?) {
        do {
            let session = try store.create()
            let fm = FileManager.default
            // Move instead of copy: the raws live in NSTemporaryDirectory
            // and would otherwise get reaped by the OS.
            try fm.moveItem(at: rawURL, to: session.screenURL)
            try fm.moveItem(at: cameraURL, to: session.cameraURL)
            try store.saveBubbleTimeline(bubbleTimeline, to: session)
            setRecordingOnMain(false)
            DispatchQueue.main.async {
                completion?(.success(session))
            }
        } catch {
            try? FileManager.default.removeItem(at: rawURL)
            try? FileManager.default.removeItem(at: cameraURL)
            DebugLog.log("pipeline", "persistSession failed: \(error.localizedDescription)")
            finishWithError(error, completion: completion)
        }
    }

    private func finishWithError(_ error: Error,
                                 completion: ((Result<RecordedSession, SelfieOverlayError>) -> Void)?) {
        setRecordingOnMain(false)
        DispatchQueue.main.async {
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
