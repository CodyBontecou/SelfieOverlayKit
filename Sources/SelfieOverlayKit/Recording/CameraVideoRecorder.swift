import AVFoundation
import CoreMedia

/// Records the live front-camera feed to a dedicated temp `.mov` alongside the
/// `RPScreenRecorder` screen capture. The compositor consumes both streams plus
/// a `BubbleTimeline` to produce the final export with the selfie baked in,
/// which is more reliable than hoping ReplayKit's in-app capture picks up the
/// overlay window (it often doesn't for windows above the host hierarchy).
final class CameraVideoRecorder {

    enum CameraRecorderError: Error {
        case writerInitFailed(Error)
        case writerFinishFailed(Error?)
        case notStarted
    }

    private weak var cameraSession: CameraSession?
    private let queue = DispatchQueue(label: "SelfieOverlayKit.CameraVideoRecorder")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var outputURL: URL?
    private var didStartSession = false

    /// Fires once on the main queue with the first-sample PTS in `CACurrentMediaTime()`
    /// units — the same host clock `RawRecorder.onVideoStart` emits, so callers can align.
    var onVideoStart: ((TimeInterval) -> Void)?

    private(set) var firstSamplePTS: CMTime?

    func start(cameraSession: CameraSession,
               completion: @escaping (Result<Void, Error>) -> Void) {
        self.cameraSession = cameraSession

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("selfieoverlay-camera-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)
        outputURL = url
        didStartSession = false
        firstSamplePTS = nil

        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            // Portrait front camera under the `.high` preset — picked to match what the
            // sample buffers actually carry so the writer doesn't have to rescale.
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 720,
                AVVideoHeightKey: 1280
            ]
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            i.expectsMediaDataInRealTime = true
            if w.canAdd(i) { w.add(i) }
            writer = w
            input = i
        } catch {
            completion(.failure(CameraRecorderError.writerInitFailed(error)))
            return
        }

        cameraSession.addSampleBufferListener(self) { [weak self] sample in
            self?.queue.async { self?.handle(sample) }
        }

        completion(.success(()))
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        cameraSession?.removeSampleBufferListener(self)

        queue.async { [weak self] in
            guard let self, let writer = self.writer else {
                DispatchQueue.main.async {
                    completion(.failure(CameraRecorderError.notStarted))
                }
                return
            }
            // No camera sample ever arrived — writer never transitioned out of .unknown,
            // and calling markAsFinished in that state throws NSInternalInconsistencyException.
            guard writer.status == .writing else {
                if let url = self.outputURL {
                    try? FileManager.default.removeItem(at: url)
                }
                self.writer = nil
                self.input = nil
                self.outputURL = nil
                DispatchQueue.main.async {
                    completion(.failure(CameraRecorderError.notStarted))
                }
                return
            }
            self.input?.markAsFinished()
            writer.finishWriting { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if writer.status == .completed, let url = self.outputURL {
                        completion(.success(url))
                    } else {
                        completion(.failure(
                            CameraRecorderError.writerFinishFailed(writer.error)))
                    }
                }
            }
        }
    }

    private func handle(_ sample: CMSampleBuffer) {
        guard let writer else { return }
        guard CMSampleBufferDataIsReady(sample) else { return }

        if !didStartSession, writer.status == .unknown {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if writer.startWriting() {
                writer.startSession(atSourceTime: pts)
                didStartSession = true
                firstSamplePTS = pts
                let seconds = CMTimeGetSeconds(pts)
                DispatchQueue.main.async { [weak self] in
                    self?.onVideoStart?(seconds)
                }
            }
        }

        guard writer.status == .writing,
              let input,
              input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }
}
