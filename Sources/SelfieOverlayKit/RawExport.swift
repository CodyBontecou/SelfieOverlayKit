import AVFoundation
import CoreMedia
import Foundation
import UIKit

/// Output of `SelfieOverlayKit.stopRecording(exportTo:)` — the raw tracks, the
/// bubble timeline JSON, and a pre-composited `final.mov` showing the screen
/// with the camera baked into its bubble.
public struct RawExportBundle {

    /// ReplayKit screen capture (.mov). Video-only when `audioURL` is non-nil
    /// — the mic audio is moved into `audio.m4a` so the two live in exactly
    /// one place each. When `demuxAudio` was passed as `false`, the mic
    /// remains embedded here instead.
    public let screenURL: URL

    /// Front-camera selfie (.mov), video-only.
    public let cameraURL: URL

    /// Demuxed mic audio (.m4a). `nil` when the recording was started
    /// without a microphone, or when the caller passed `demuxAudio: false`.
    /// When non-nil, the audio is no longer embedded in `screenURL`.
    public let audioURL: URL?

    /// `bubble.json` — selfie position, size, shape, mirror, and opacity
    /// sampled over the recording. SDK-specific schema; host apps read this
    /// directly if they want to recreate the selfie overlay in their editor.
    public let bubbleTimelineURL: URL

    /// `final.mov` — screen recording with the camera composited into its
    /// bubble (shape/mirror/opacity sampled from the timeline) and audio
    /// muxed in. Produced from the other four files; host apps can ship this
    /// directly without running the editor app.
    public let finalURL: URL

    /// Duration of the screen recording.
    public let duration: CMTime
}

/// Copies the raw tracks from a completed recording to a host-app-supplied
/// destination directory and (optionally) demuxes the mic audio into a
/// standalone .m4a. The source folder is left untouched — the host app is
/// responsible for cleanup if it doesn't want the SDK's internal copy
/// hanging around.
enum RawExporter {

    enum Failure: Error, LocalizedError {
        case destinationNotADirectory(URL)
        case missingSourceFile(URL)
        case audioExportFailed(String)
        case audioStripFailed(String)
        case bubbleTimelineReadFailed(String)

        var errorDescription: String? {
            switch self {
            case .destinationNotADirectory(let url):
                return "Raw export destination is not a directory: \(url.path)"
            case .missingSourceFile(let url):
                return "Source file missing for raw export: \(url.lastPathComponent)"
            case .audioExportFailed(let reason):
                return "Audio demux failed: \(reason)"
            case .audioStripFailed(let reason):
                return "Failed to strip audio from screen recording: \(reason)"
            case .bubbleTimelineReadFailed(let reason):
                return "Failed to decode bubble.json for final compose: \(reason)"
            }
        }
    }

    static let screenFilename = "screen.mov"
    static let cameraFilename = "camera.mov"
    static let audioFilename = "audio.m4a"
    static let bubbleFilename = "bubble.json"
    static let finalFilename = FinalCompositor.finalFilename

    /// Convenience overload used by the recording pipeline — takes a
    /// `RecordedSession` and forwards to the URL-based entry point.
    static func export(
        session: RecordedSession,
        to destination: URL,
        demuxAudio: Bool,
        completion: @escaping (Result<RawExportBundle, Error>) -> Void
    ) {
        export(
            sourceScreenURL: session.screenURL,
            sourceCameraURL: session.cameraURL,
            sourceBubbleTimelineURL: session.bubbleTimelineURL,
            to: destination,
            demuxAudio: demuxAudio,
            pointBounds: nil,
            completion: completion)
    }

    /// `pointBounds` is the coordinate space `BubbleTimeline` frames live in —
    /// pass `nil` to default to `UIScreen.main.bounds.size` (the space the
    /// live bubble was logged in). Tests override it to decouple from device
    /// geometry.
    static func export(
        sourceScreenURL: URL,
        sourceCameraURL: URL,
        sourceBubbleTimelineURL: URL,
        to destination: URL,
        demuxAudio: Bool,
        pointBounds: CGSize? = nil,
        completion: @escaping (Result<RawExportBundle, Error>) -> Void
    ) {
        let resolvedBounds = pointBounds ?? UIScreen.main.bounds.size

        let copied: CopyResult
        do {
            copied = try copySourceFiles(
                sourceScreenURL: sourceScreenURL,
                sourceCameraURL: sourceCameraURL,
                sourceBubbleTimelineURL: sourceBubbleTimelineURL,
                to: destination)
        } catch {
            completion(.failure(error))
            return
        }

        guard demuxAudio else {
            composeFinal(copied: copied, audioURL: nil, pointBounds: resolvedBounds, completion: completion)
            return
        }

        let audioDestination = destination.appendingPathComponent(audioFilename)
        demuxAudioIfPresent(from: copied.screenURL, to: audioDestination) { audioResult in
            switch audioResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(nil):
                // Source had no audio — nothing to strip from the screen copy.
                composeFinal(copied: copied, audioURL: nil, pointBounds: resolvedBounds, completion: completion)
            case .success(let audioURL?):
                // Audio was moved into audio.m4a — re-export screen.mov as
                // video-only so the mic lives in exactly one place.
                stripAudio(from: copied.screenURL) { stripResult in
                    switch stripResult {
                    case .success:
                        composeFinal(copied: copied, audioURL: audioURL, pointBounds: resolvedBounds, completion: completion)
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    // MARK: - Final compose

    private static func composeFinal(
        copied: CopyResult,
        audioURL: URL?,
        pointBounds: CGSize,
        completion: @escaping (Result<RawExportBundle, Error>) -> Void
    ) {
        let timeline: BubbleTimeline
        do {
            let data = try Data(contentsOf: copied.bubbleTimelineURL)
            timeline = try JSONDecoder().decode(BubbleTimeline.self, from: data)
        } catch {
            completion(.failure(Failure.bubbleTimelineReadFailed(error.localizedDescription)))
            return
        }

        let finalURL = copied.bubbleTimelineURL
            .deletingLastPathComponent()
            .appendingPathComponent(finalFilename)

        FinalCompositor.compose(
            screenURL: copied.screenURL,
            cameraURL: copied.cameraURL,
            audioURL: audioURL,
            bubbleTimeline: timeline,
            pointBounds: pointBounds,
            to: finalURL
        ) { result in
            switch result {
            case .success:
                completion(.success(copied.bundle(audioURL: audioURL, finalURL: finalURL)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Copy

    private struct CopyResult {
        let screenURL: URL
        let cameraURL: URL
        let bubbleTimelineURL: URL
        let duration: CMTime

        func bundle(audioURL: URL?, finalURL: URL) -> RawExportBundle {
            RawExportBundle(
                screenURL: screenURL,
                cameraURL: cameraURL,
                audioURL: audioURL,
                bubbleTimelineURL: bubbleTimelineURL,
                finalURL: finalURL,
                duration: duration)
        }
    }

    private static func copySourceFiles(sourceScreenURL: URL,
                                        sourceCameraURL: URL,
                                        sourceBubbleTimelineURL: URL,
                                        to destination: URL) throws -> CopyResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw Failure.destinationNotADirectory(destination)
            }
        } else {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        for url in [sourceScreenURL, sourceCameraURL, sourceBubbleTimelineURL] {
            guard fm.fileExists(atPath: url.path) else {
                throw Failure.missingSourceFile(url)
            }
        }

        let screenDest = destination.appendingPathComponent(screenFilename)
        let cameraDest = destination.appendingPathComponent(cameraFilename)
        let bubbleDest = destination.appendingPathComponent(bubbleFilename)

        for dest in [screenDest, cameraDest, bubbleDest] {
            try? fm.removeItem(at: dest)
        }
        try fm.copyItem(at: sourceScreenURL, to: screenDest)
        try fm.copyItem(at: sourceCameraURL, to: cameraDest)
        try fm.copyItem(at: sourceBubbleTimelineURL, to: bubbleDest)

        let asset = AVURLAsset(url: screenDest)
        return CopyResult(
            screenURL: screenDest,
            cameraURL: cameraDest,
            bubbleTimelineURL: bubbleDest,
            duration: asset.duration)
    }

    // MARK: - Audio demux

    /// Resolves with a non-nil URL when an audio.m4a was written, or `.success(nil)`
    /// when the source has no audio track (recording was started without mic).
    private static func demuxAudioIfPresent(
        from screenURL: URL,
        to audioURL: URL,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let asset = AVURLAsset(url: screenURL)
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            var statusError: NSError?
            let status = asset.statusOfValue(forKey: "tracks", error: &statusError)
            guard status == .loaded else {
                completion(.failure(Failure.audioExportFailed(
                    statusError?.localizedDescription ?? "track load status \(status.rawValue)")))
                return
            }

            let audioTracks = asset.tracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                completion(.success(nil))
                return
            }

            try? FileManager.default.removeItem(at: audioURL)
            guard let session = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                completion(.failure(Failure.audioExportFailed("AppleM4A preset unavailable")))
                return
            }
            session.outputURL = audioURL
            session.outputFileType = .m4a
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    completion(.success(audioURL))
                case .cancelled:
                    completion(.failure(Failure.audioExportFailed("cancelled")))
                case .failed:
                    completion(.failure(Failure.audioExportFailed(
                        session.error?.localizedDescription ?? "unknown")))
                default:
                    completion(.failure(Failure.audioExportFailed(
                        "unexpected status \(session.status.rawValue)")))
                }
            }
        }
    }

    // MARK: - Audio strip

    /// Re-exports `videoURL` in place with only its video tracks (passthrough,
    /// no re-encode). Used after the audio has been demuxed to `audio.m4a` so
    /// the mic doesn't end up embedded in screen.mov as well.
    private static func stripAudio(
        from videoURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let asset = AVURLAsset(url: videoURL)
        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
            var statusError: NSError?
            let status = asset.statusOfValue(forKey: "tracks", error: &statusError)
            guard status == .loaded else {
                completion(.failure(Failure.audioStripFailed(
                    statusError?.localizedDescription ?? "track load status \(status.rawValue)")))
                return
            }

            let videoTracks = asset.tracks(withMediaType: .video)
            guard !videoTracks.isEmpty else {
                completion(.failure(Failure.audioStripFailed("no video tracks in source")))
                return
            }

            let composition = AVMutableComposition()
            let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
            for track in videoTracks {
                guard let compTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                do {
                    try compTrack.insertTimeRange(timeRange, of: track, at: .zero)
                    compTrack.preferredTransform = track.preferredTransform
                } catch {
                    completion(.failure(Failure.audioStripFailed(error.localizedDescription)))
                    return
                }
            }

            let tempURL = videoURL.deletingLastPathComponent()
                .appendingPathComponent(".tmp-strip-\(UUID().uuidString).mov")
            guard let session = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                completion(.failure(Failure.audioStripFailed("Passthrough preset unavailable")))
                return
            }
            session.outputURL = tempURL
            session.outputFileType = .mov
            session.exportAsynchronously {
                let fm = FileManager.default
                switch session.status {
                case .completed:
                    do {
                        try? fm.removeItem(at: videoURL)
                        try fm.moveItem(at: tempURL, to: videoURL)
                        completion(.success(()))
                    } catch {
                        try? fm.removeItem(at: tempURL)
                        completion(.failure(Failure.audioStripFailed(
                            "replace failed: \(error.localizedDescription)")))
                    }
                case .cancelled:
                    try? fm.removeItem(at: tempURL)
                    completion(.failure(Failure.audioStripFailed("cancelled")))
                case .failed:
                    try? fm.removeItem(at: tempURL)
                    completion(.failure(Failure.audioStripFailed(
                        session.error?.localizedDescription ?? "unknown")))
                default:
                    try? fm.removeItem(at: tempURL)
                    completion(.failure(Failure.audioStripFailed(
                        "unexpected status \(session.status.rawValue)")))
                }
            }
        }
    }
}
