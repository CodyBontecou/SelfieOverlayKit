import AVFoundation
import Combine
import CoreMedia
import Foundation
import UIKit

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
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var sentinelURL: URL?

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
                      fileType: AVFileType = .mp4,
                      sentinelURL: URL? = nil) {
        guard state == .notStarted else { return }
        try? FileManager.default.removeItem(at: outputURL)

        if let shortfall = Self.diskSpaceShortfall(
            for: composition, outputDirectory: outputURL.deletingLastPathComponent()) {
            let neededMB = (shortfall + 1_048_575) / 1_048_576
            state = .failed(errorDescription:
                "Not enough storage to export. Free up about \(neededMB) MB and try again.")
            return
        }

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
        self.sentinelURL = sentinelURL
        if let sentinelURL {
            // Best-effort: create the sentinel as an empty file. If the write
            // fails we still proceed with the export — missing sentinel just
            // means we can't detect a subsequent mid-export termination.
            FileManager.default.createFile(atPath: sentinelURL.path, contents: nil)
        }
        state = .exporting
        startProgressTimer()
        beginBackgroundTask()

        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.stopProgressTimer()
                self.clearSentinel()
                switch session.status {
                case .completed:
                    self.progress = 1.0
                    self.state = .completed(outputURL)
                case .cancelled:
                    self.state = .cancelled
                    try? FileManager.default.removeItem(at: outputURL)
                case .failed:
                    // Prefer the underlying NSError so low-storage /
                    // permissions / codec failures surface with their actual
                    // message rather than a generic "export failed".
                    let desc = (session.error as NSError?).map {
                        $0.localizedDescription + ($0.localizedFailureReason.map { " — \($0)" } ?? "")
                    } ?? "export failed"
                    self.state = .failed(errorDescription: desc)
                    try? FileManager.default.removeItem(at: outputURL)
                default:
                    // AVAssetExportSession never calls back with .waiting / .exporting
                    // on the completion handler — keep the compiler happy.
                    break
                }
                self.endBackgroundTask()
            }
        }
    }

    // MARK: - Background task

    /// Request ~30 s of background runtime so a user who flips away
    /// mid-export doesn't have the export session killed out from under us
    /// for short trips. AVAssetExportSession can't resume, so the expiration
    /// handler cancels cleanly — the sentinel file survives and the editor
    /// can prompt "previous export was interrupted" on relaunch.
    private func beginBackgroundTask() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SelfieOverlayKit.Exporter") { [weak self] in
            self?.session?.cancelExport()
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Sentinel file

    private func clearSentinel() {
        if let sentinelURL {
            try? FileManager.default.removeItem(at: sentinelURL)
        }
        sentinelURL = nil
    }

    // MARK: - Disk-space preflight

    /// Returns the number of bytes the output directory is short, or `nil`
    /// when there is enough free space for a safe export.
    ///
    /// Estimates output size as (sum of track data rates × duration) with a
    /// 50% safety margin — AVAssetExportSession has no sync API for this on
    /// iOS 15, so we pay a small over-estimate to avoid mid-export
    /// out-of-space failures.
    static func diskSpaceShortfall(
        for composition: AVComposition,
        outputDirectory: URL,
        freeBytesProvider: (URL) -> Int64? = Exporter.defaultFreeBytes
    ) -> Int64? {
        let seconds = max(composition.duration.seconds, 0)
        guard seconds > 0 else { return nil }

        let dataRateBitsPerSec = composition.tracks
            .map { Double($0.estimatedDataRate) }
            .reduce(0, +)
        // Floor at 2 Mbps so zero-rate tracks (e.g. AVMutableCompositionTrack
        // before finalization reports 0) still yield a sane lower bound.
        let effectiveRate = max(dataRateBitsPerSec, 2_000_000)
        let estimatedBytes = Int64(effectiveRate * seconds / 8.0)
        let required = Int64(Double(estimatedBytes) * 1.5)

        guard let free = freeBytesProvider(outputDirectory) else { return nil }
        return free < required ? (required - free) : nil
    }

    private static func defaultFreeBytes(_ directory: URL) -> Int64? {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value
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
