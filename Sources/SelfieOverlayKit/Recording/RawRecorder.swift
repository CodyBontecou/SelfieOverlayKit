import AVFoundation
import CoreMedia
import ReplayKit
import UIKit

/// Drives `RPScreenRecorder.startCapture(handler:)` and writes the resulting
/// video (+ optional microphone audio) to a temp `.mov` via `AVAssetWriter`.
///
/// The raw file is intentionally unprocessed — `CameraCompositor` consumes it
/// alongside the camera recording and a `BubbleTimeline` to produce the final
/// export.
final class RawRecorder {

    enum RawError: Error {
        case writerInitFailed(Error)
        case writerFinishFailed(Error?)
    }

    private let recorder = RPScreenRecorder.shared()
    private let queue = DispatchQueue(label: "SelfieOverlayKit.RawRecorder")

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var startedSession = false

    /// Fires once, on the main queue, when the first video buffer is written.
    /// Carries the video's first-sample PTS in `CACurrentMediaTime()` units so
    /// callers can align their own time-stamped events with video time.
    var onVideoStart: ((TimeInterval) -> Void)?

    var isCapturing: Bool { recorder.isRecording }

    func start(withMicrophone: Bool,
               completion: @escaping (Result<Void, Error>) -> Void) {
        guard recorder.isAvailable else {
            completion(.failure(SelfieOverlayError.recordingUnavailable))
            return
        }
        guard !recorder.isRecording else {
            completion(.failure(SelfieOverlayError.recordingAlreadyInProgress))
            return
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("selfieoverlay-raw-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)
        outputURL = url
        startedSession = false

        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)

            let screen = UIScreen.main.bounds.size
            let scale = UIScreen.main.scale
            let pixelWidth = Int(screen.width * scale)
            let pixelHeight = Int(screen.height * scale)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: pixelWidth,
                AVVideoHeightKey: pixelHeight
            ]
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true
            if w.canAdd(vInput) { w.add(vInput) }
            videoInput = vInput

            if withMicrophone {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 44100,
                    AVEncoderBitRateKey: 128_000
                ]
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                aInput.expectsMediaDataInRealTime = true
                if w.canAdd(aInput) { w.add(aInput) }
                micInput = aInput
            } else {
                micInput = nil
            }

            writer = w
        } catch {
            completion(.failure(RawError.writerInitFailed(error)))
            return
        }

        recorder.isMicrophoneEnabled = withMicrophone
        recorder.startCapture(handler: { [weak self] sample, type, error in
            guard let self, error == nil else { return }
            self.queue.async { self.handle(sample: sample, type: type) }
        }, completionHandler: { error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        })
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard recorder.isRecording else {
            completion(.failure(SelfieOverlayError.recordingNotInProgress))
            return
        }
        recorder.stopCapture { [weak self] error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            self.queue.async { self.finishWriting(completion: completion) }
        }
    }

    private func finishWriting(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let writer else {
            DispatchQueue.main.async {
                completion(.failure(RawError.writerFinishFailed(nil)))
            }
            return
        }
        videoInput?.markAsFinished()
        micInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if writer.status == .completed, let url = self.outputURL {
                    completion(.success(url))
                } else {
                    completion(.failure(RawError.writerFinishFailed(writer.error)))
                }
            }
        }
    }

    private func handle(sample: CMSampleBuffer, type: RPSampleBufferType) {
        guard let writer else { return }
        guard CMSampleBufferDataIsReady(sample) else { return }

        if !startedSession, type == .video, writer.status == .unknown {
            let start = CMSampleBufferGetPresentationTimeStamp(sample)
            if writer.startWriting() {
                writer.startSession(atSourceTime: start)
                startedSession = true
                let seconds = CMTimeGetSeconds(start)
                DispatchQueue.main.async { [weak self] in
                    self?.onVideoStart?(seconds)
                }
            }
        }

        guard writer.status == .writing else { return }

        switch type {
        case .video:
            if let input = videoInput, input.isReadyForMoreMediaData {
                input.append(sample)
            }
        case .audioMic:
            if let input = micInput, input.isReadyForMoreMediaData {
                input.append(sample)
            }
        case .audioApp:
            // Intentionally skipped for v1 — mixing app audio alongside mic
            // via AVAssetWriter is fragile; mic alone covers the primary
            // narration use case (tutorials, reaction videos, demos).
            break
        @unknown default:
            break
        }
    }
}
