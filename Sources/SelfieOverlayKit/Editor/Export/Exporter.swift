import AVFoundation
import Combine
import CoreMedia
import Foundation

/// Wraps `AVAssetExportSession` with a progress stream + cancel support.
/// The editor's Save / Share flows use this instead of calling the export
/// session directly so the UI can show a determinate progress sheet and
/// bail mid-export without corrupting the project folder.
///
/// The fallback reader/writer path described in the T14 ticket is deferred
/// pending device verification — `AVAssetExportSession` accepts
/// `BubbleVideoCompositor` in our current testing, so the primary path is
/// sufficient. See ticket notes for the decision.
public final class Exporter {

    // MARK: - Public API

    public enum State: Equatable {
        case notStarted
        case exporting
        case completed(URL)
        case cancelled
        case failed(errorDescription: String)
    }

    @Published public private(set) var state: State = .notStarted
    @Published public private(set) var progress: Double = 0.0

    /// Emits when the export finishes for any reason (completed, cancelled,
    /// or failed). Subscribers that need a one-shot completion hook can wait
    /// on this instead of diffing `state` changes.
    public var done: AnyPublisher<State, Never> {
        $state
            .filter { state in
                switch state {
                case .completed, .cancelled, .failed: return true
                default: return false
                }
            }
            .first()
            .eraseToAnyPublisher()
    }

    // MARK: - Construction

    private let composition: AVComposition
    private let videoComposition: AVVideoComposition
    private let audioMix: AVAudioMix
    private let presetName: String

    private var session: AVAssetExportSession?
    private var progressTimer: Timer?

    public init(composition: AVComposition,
                videoComposition: AVVideoComposition,
                audioMix: AVAudioMix,
                presetName: String = AVAssetExportPresetHighestQuality) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.presetName = presetName
    }

    deinit {
        progressTimer?.invalidate()
    }

    // MARK: - Control

    public func start(outputURL: URL,
                      fileType: AVFileType = .mp4) {
        guard state == .notStarted else { return }
        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(
            asset: composition, presetName: presetName) else {
            state = .failed(errorDescription: "AVAssetExportSession unavailable for preset \(presetName)")
            return
        }
        session.outputURL = outputURL
        session.outputFileType = fileType
        session.videoComposition = videoComposition
        session.audioMix = audioMix

        self.session = session
        state = .exporting
        startProgressTimer()

        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.stopProgressTimer()
                switch session.status {
                case .completed:
                    self.progress = 1.0
                    self.state = .completed(outputURL)
                case .cancelled:
                    self.state = .cancelled
                    try? FileManager.default.removeItem(at: outputURL)
                case .failed:
                    let desc = session.error?.localizedDescription ?? "export failed"
                    self.state = .failed(errorDescription: desc)
                    try? FileManager.default.removeItem(at: outputURL)
                default:
                    // AVAssetExportSession never calls back with .waiting / .exporting
                    // on the completion handler — keep the compiler happy.
                    break
                }
            }
        }
    }

    public func cancel() {
        session?.cancelExport()
    }

    // MARK: - Progress polling

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let session = self.session else { return }
            // AVAssetExportSession.progress rises 0→1; if the OS resets it to 0
            // on cancellation the state transition below will override anyway.
            let newProgress = Double(session.progress)
            if newProgress > self.progress {
                self.progress = newProgress
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
