import AVFoundation
import CoreImage
import CoreMedia
import UIKit

/// Reads the raw screen recording and the raw camera recording, composites the
/// selfie bubble on top of each screen frame using the `BubbleTimeline`, and
/// passes any audio track on the screen recording straight through. Writes a
/// single `.mp4` ready for preview/share/save.
///
/// Compositing the camera in post (rather than hoping ReplayKit's in-app
/// capture picks up the overlay window) is what guarantees the selfie actually
/// lands in the exported video.
final class CameraCompositor {

    struct Inputs {
        let screenURL: URL
        let cameraURL: URL
        let bubbleTimeline: BubbleTimeline
        /// Points-to-pixels factor for the bubble frame (e.g., `UIScreen.main.scale`).
        let screenScale: CGFloat
    }

    enum CompositorError: Error {
        case trackMissing
        case readerInitFailed(Error)
        case writerInitFailed(Error)
        case startWritingFailed(Error?)
        case exportFailed(Error?)
    }

    struct Progress {
        let framesProcessed: Int
        let estimatedTotalFrames: Int?
        let elapsedSeconds: TimeInterval
    }

    /// Fires on an arbitrary queue every ~30 frames during compositing so callers
    /// can surface progress (e.g., to the processing HUD).
    var onProgress: ((Progress) -> Void)?

    /// Fires on an arbitrary queue as the compositor transitions between setup
    /// phases. Pairs with `onProgress` so the HUD can show whether we're stuck
    /// in setup vs. stuck between frames.
    var onStatus: ((String) -> Void)?

    private func notify(_ phase: String) {
        DebugLog.log("compositor", phase)
        onStatus?(phase)
    }

    private let ciContext: CIContext = {
        let device = MTLCreateSystemDefaultDevice()
        return device.map { CIContext(mtlDevice: $0) } ?? CIContext()
    }()

    private let workQueue = DispatchQueue(
        label: "SelfieOverlayKit.CameraCompositor", qos: .userInitiated)
    private let videoQueue = DispatchQueue(
        label: "SelfieOverlayKit.CameraCompositor.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(
        label: "SelfieOverlayKit.CameraCompositor.audio", qos: .userInitiated)

    private let overlayRenderer = BubbleOverlayRenderer()

    func composite(_ inputs: Inputs,
                   completion: @escaping (Result<URL, Error>) -> Void) {
        // Strong `self`: the caller typically holds this compositor only as a
        // local in its closure, so a weak capture lets the instance deallocate
        // before the async work starts and silently drops the composite.
        workQueue.async {
            do {
                let url = try self.perform(inputs)
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Pipeline

    private func perform(_ inputs: Inputs) throws -> URL {
        let startedAt = CACurrentMediaTime()
        notify("Opening recordings")
        let screenAsset = AVURLAsset(url: inputs.screenURL)
        let cameraAsset = AVURLAsset(url: inputs.cameraURL)

        notify("Reading track metadata")
        guard let screenVideoTrack = screenAsset.tracks(withMediaType: .video).first,
              let cameraVideoTrack = cameraAsset.tracks(withMediaType: .video).first else {
            DebugLog.log("compositor", "missing tracks: screen=\(screenAsset.tracks(withMediaType: .video).count) camera=\(cameraAsset.tracks(withMediaType: .video).count)")
            throw CompositorError.trackMissing
        }
        let screenAudioTrack = screenAsset.tracks(withMediaType: .audio).first

        let screenSize = screenVideoTrack.naturalSize
        let outputWidth = Int(screenSize.width.rounded())
        let outputHeight = Int(screenSize.height.rounded())
        let outputSize = CGSize(width: outputWidth, height: outputHeight)

        let screenDuration = CMTimeGetSeconds(screenAsset.duration)
        let screenFPS = Double(screenVideoTrack.nominalFrameRate)
        let cameraDuration = CMTimeGetSeconds(cameraAsset.duration)
        let cameraFPS = Double(cameraVideoTrack.nominalFrameRate)
        let estimatedTotalFrames: Int? = screenFPS > 0
            ? Int((screenDuration * screenFPS).rounded())
            : nil
        DebugLog.log("compositor", 
            "begin: output=\(outputWidth)×\(outputHeight) screen=\(String(format: "%.2f", screenDuration))s@\(String(format: "%.1f", screenFPS))fps camera=\(String(format: "%.2f", cameraDuration))s@\(String(format: "%.1f", cameraFPS))fps hasAudio=\(screenAudioTrack != nil) estFrames=\(estimatedTotalFrames ?? -1)")

        notify("Initializing readers")
        let screenVideoReader: AVAssetReader
        let cameraReader: AVAssetReader
        do {
            screenVideoReader = try AVAssetReader(asset: screenAsset)
            cameraReader = try AVAssetReader(asset: cameraAsset)
        } catch {
            throw CompositorError.readerInitFailed(error)
        }

        let bgra: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let screenVideoOut = AVAssetReaderTrackOutput(
            track: screenVideoTrack, outputSettings: bgra)
        let cameraOut = AVAssetReaderTrackOutput(
            track: cameraVideoTrack, outputSettings: bgra)
        screenVideoReader.add(screenVideoOut)
        cameraReader.add(cameraOut)

        // Decode the source AAC to LPCM here so the writer can re-encode to AAC
        // in the output container. Straight passthrough (outputSettings: nil)
        // loses the source MOV's edit list / AAC priming offset when copied into
        // an MP4, which shifts audio ~48 ms ahead of video in the export.
        //
        // Clamp the reader's timeRange to the video track's start so any audio
        // ReplayKit captured before the first video frame is skipped — otherwise
        // that extra pre-video audio ends up at the head of the export and
        // plays ahead of the video for the rest of the clip.
        var audioReader: AVAssetReader?
        var audioOut: AVAssetReaderTrackOutput?
        if let screenAudioTrack {
            let reader = try AVAssetReader(asset: screenAsset)
            reader.timeRange = CMTimeRange(
                start: screenVideoTrack.timeRange.start,
                duration: .positiveInfinity)
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let out = AVAssetReaderTrackOutput(track: screenAudioTrack, outputSettings: pcmSettings)
            reader.add(out)
            audioReader = reader
            audioOut = out
            let vStart = CMTimeGetSeconds(screenVideoTrack.timeRange.start)
            let aStart = CMTimeGetSeconds(screenAudioTrack.timeRange.start)
            DebugLog.log("compositor", "audio sync: videoTrackStart=\(String(format: "%.4f", vStart))s audioTrackStart=\(String(format: "%.4f", aStart))s offset=\(String(format: "%+.4f", aStart - vStart))s")
        }

        notify("Initializing writer")
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("selfieoverlay-final-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        } catch {
            throw CompositorError.writerInitFailed(error)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight
            ])
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOut != nil, let screenAudioTrack {
            var sampleRate: Double = 44100
            var channels: Int = 2
            if let fmt = screenAudioTrack.formatDescriptions.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                fmt as! CMAudioFormatDescription)?.pointee {
                if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
                if asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
            }
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: channels,
                AVSampleRateKey: sampleRate,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                DebugLog.log("compositor", "writer.canAdd(audio) returned false; export will be silent")
            }
        }

        notify("Starting writer")
        guard writer.startWriting() else {
            DebugLog.log("compositor", "startWriting failed: \(String(describing: writer.error))")
            throw CompositorError.startWritingFailed(writer.error)
        }
        notify("Starting readers")
        guard screenVideoReader.startReading(), cameraReader.startReading() else {
            writer.cancelWriting()
            DebugLog.log("compositor", "startReading failed: screen=\(String(describing: screenVideoReader.error)) camera=\(String(describing: cameraReader.error))")
            throw CompositorError.exportFailed(
                screenVideoReader.error ?? cameraReader.error)
        }
        _ = audioReader?.startReading()
        DebugLog.log("compositor", "readers + writer started")

        notify("Buffering first camera frame")
        // Camera lookahead: hold the most recent camera frame ≤ screen PTS, peeking
        // one ahead to know when to advance.
        var currentCameraFrame: CVPixelBuffer?
        var nextCameraFrame: (buffer: CVPixelBuffer, pts: CMTime)? = nil
        if let first = cameraOut.copyNextSampleBuffer(),
           let buf = CMSampleBufferGetImageBuffer(first) {
            nextCameraFrame = (buf, CMSampleBufferGetPresentationTimeStamp(first))
            DebugLog.log("compositor", "first camera frame pts=\(String(format: "%.3f", CMTimeGetSeconds(nextCameraFrame!.pts)))s")
        } else {
            DebugLog.log("compositor", "no initial camera frame available (readerStatus=\(cameraReader.status.rawValue))")
        }
        notify("Requesting video input")

        var sessionStarted = false
        var firstScreenPTSSeconds: TimeInterval = 0
        var framesProcessed = 0
        var lastLoggedFrame = 0
        var callbackInvocations = 0
        let videoDone = DispatchSemaphore(value: 0)

        let audioDone = DispatchSemaphore(value: 0)

        // Audio pull can only start after the video callback calls startSession(atSourceTime:).
        // Appending audio before that throws NSInternalInconsistencyException, and the two
        // inputs run on separate queues with no inherent ordering.
        let startAudioPull: () -> Void = { [audioInput, audioOut, audioQueue] in
            guard let audioInput, let audioOut else {
                audioDone.signal()
                return
            }
            var audioSamplesAppended = 0
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard let sample = audioOut.copyNextSampleBuffer() else {
                        DebugLog.log("compositor", "audio reader exhausted after \(audioSamplesAppended) samples")
                        audioInput.markAsFinished()
                        audioDone.signal()
                        return
                    }
                    if audioSamplesAppended < 3 {
                        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                        let dur = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
                        DebugLog.log("compositor", "audio sample #\(audioSamplesAppended) pts=\(String(format: "%.4f", pts))s dur=\(String(format: "%.4f", dur))s")
                    }
                    if !audioInput.append(sample) {
                        DebugLog.log("compositor", "audio append failed: \(String(describing: writer.error))")
                        audioInput.markAsFinished()
                        audioDone.signal()
                        return
                    }
                    audioSamplesAppended += 1
                }
            }
        }
        var audioStarted = false

        videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
            guard let self else { return }
            callbackInvocations += 1
            if callbackInvocations == 1 {
                DebugLog.log("compositor", "video callback fired (isReadyForMoreMediaData=\(videoInput.isReadyForMoreMediaData))")
            }
            while videoInput.isReadyForMoreMediaData {
                guard let screenSample = screenVideoOut.copyNextSampleBuffer() else {
                    let elapsed = CACurrentMediaTime() - startedAt
                    DebugLog.log("compositor", "video reader exhausted after \(framesProcessed) frames in \(String(format: "%.2f", elapsed))s (readerStatus=\(screenVideoReader.status.rawValue) writerStatus=\(writer.status.rawValue))")
                    if let err = screenVideoReader.error {
                        DebugLog.log("compositor", "video reader error: \(err.localizedDescription)")
                    }
                    videoInput.markAsFinished()
                    videoDone.signal()
                    return
                }
                guard let screenBuffer = CMSampleBufferGetImageBuffer(screenSample) else {
                    continue
                }
                let screenPTS = CMSampleBufferGetPresentationTimeStamp(screenSample)

                if !sessionStarted {
                    writer.startSession(atSourceTime: screenPTS)
                    sessionStarted = true
                    firstScreenPTSSeconds = CMTimeGetSeconds(screenPTS)
                    DebugLog.log("compositor", "first frame: pts=\(String(format: "%.3f", firstScreenPTSSeconds))s")
                    if !audioStarted {
                        audioStarted = true
                        startAudioPull()
                    }
                }

                // Log the first few frames' deltas so we can see if ReplayKit
                // emits an irregular gap at the start of the recording.
                if framesProcessed < 6 {
                    let t = CMTimeGetSeconds(screenPTS) - firstScreenPTSSeconds
                    DebugLog.log("compositor", "video frame #\(framesProcessed) t=\(String(format: "%.4f", t))s pts=\(String(format: "%.4f", CMTimeGetSeconds(screenPTS)))s")
                }

                while let next = nextCameraFrame,
                      CMTimeCompare(next.pts, screenPTS) <= 0 {
                    currentCameraFrame = next.buffer
                    if let s = cameraOut.copyNextSampleBuffer(),
                       let b = CMSampleBufferGetImageBuffer(s) {
                        nextCameraFrame = (b, CMSampleBufferGetPresentationTimeStamp(s))
                    } else {
                        nextCameraFrame = nil
                    }
                }
                let cameraForFrame = currentCameraFrame ?? nextCameraFrame?.buffer

                let timelineTime = CMTimeGetSeconds(screenPTS) - firstScreenPTSSeconds
                let snapshot = inputs.bubbleTimeline.sample(at: timelineTime)

                guard let pool = adaptor.pixelBufferPool else {
                    DebugLog.log("compositor", "pixelBufferPool nil at frame \(framesProcessed)")
                    continue
                }
                var outBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                guard let outBuffer else {
                    DebugLog.log("compositor", "pool gave nil pixel buffer at frame \(framesProcessed)")
                    continue
                }

                self.renderFrame(
                    screenBuffer: screenBuffer,
                    cameraBuffer: cameraForFrame,
                    snapshot: snapshot,
                    screenScale: inputs.screenScale,
                    into: outBuffer,
                    outputSize: outputSize)

                if !adaptor.append(outBuffer, withPresentationTime: screenPTS) {
                    DebugLog.log("compositor", "append failed at frame \(framesProcessed) writerStatus=\(writer.status.rawValue) err=\(String(describing: writer.error))")
                    videoInput.markAsFinished()
                    videoDone.signal()
                    return
                }

                framesProcessed += 1
                // Report the first frame immediately, then every 5 frames — a 1s
                // recording is only ~30 frames so waiting for a wider window would
                // give the user no feedback at all.
                let shouldReport = framesProcessed == 1 ||
                    framesProcessed - lastLoggedFrame >= 5
                if shouldReport {
                    lastLoggedFrame = framesProcessed
                    let elapsed = CACurrentMediaTime() - startedAt
                    let fps = elapsed > 0 ? Double(framesProcessed) / elapsed : 0
                    DebugLog.log("compositor", "progress: \(framesProcessed)/\(estimatedTotalFrames ?? -1) frames @ \(String(format: "%.1f", fps)) fps (elapsed \(String(format: "%.2f", elapsed))s)")
                    self.onProgress?(Progress(
                        framesProcessed: framesProcessed,
                        estimatedTotalFrames: estimatedTotalFrames,
                        elapsedSeconds: elapsed))
                }
            }
        }

        DebugLog.log("compositor", "waiting on video + audio inputs")
        videoDone.wait()
        // If the video callback never started the session (e.g. no screen frames at all),
        // audioStarted is still false and the audio semaphore would never be signalled.
        if !audioStarted {
            audioStarted = true
            if let audioInput { audioInput.markAsFinished() }
            audioDone.signal()
        }
        audioDone.wait()
        DebugLog.log("compositor", "inputs done, calling finishWriting")

        let finishDone = DispatchSemaphore(value: 0)
        writer.finishWriting { finishDone.signal() }
        finishDone.wait()

        let totalElapsed = CACurrentMediaTime() - startedAt
        DebugLog.log("compositor", "finishWriting returned: status=\(writer.status.rawValue) frames=\(framesProcessed) totalElapsed=\(String(format: "%.2f", totalElapsed))s")

        if writer.status == .completed {
            return outURL
        }
        throw CompositorError.exportFailed(writer.error)
    }

    // MARK: - Frame rendering

    private func renderFrame(screenBuffer: CVPixelBuffer,
                             cameraBuffer: CVPixelBuffer?,
                             snapshot: BubbleTimeline.Snapshot?,
                             screenScale: CGFloat,
                             into outputBuffer: CVPixelBuffer,
                             outputSize: CGSize) {
        overlayRenderer.render(
            screen: screenBuffer,
            camera: cameraBuffer,
            state: snapshot.map(BubbleOverlayRenderer.State.init(snapshot:)),
            screenScale: screenScale,
            outputSize: outputSize,
            into: outputBuffer,
            context: ciContext)
    }
}
