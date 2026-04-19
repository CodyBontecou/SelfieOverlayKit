import AVFoundation
import CoreMedia
import Foundation

/// Output of `SelfieOverlayKit.stopRecording(exportTo:)` — the three raw
/// tracks plus the bubble timeline JSON, suitable for editing in an external
/// NLE (Premiere, FCP, Resolve) instead of the in-app editor.
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

    /// Duration of the screen recording.
    public let duration: CMTime
}

/// Copies a recorded `EditorProject`'s raw tracks out to a host-app-supplied
/// destination directory and (optionally) demuxes the mic audio into a
/// standalone .m4a. The project folder itself is left untouched — the host
/// app is responsible for cleanup if it doesn't want the SDK's internal copy
/// hanging around.
enum RawExporter {

    enum Failure: Error, LocalizedError {
        case destinationNotADirectory(URL)
        case missingSourceFile(URL)
        case audioExportFailed(String)
        case audioStripFailed(String)

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
            }
        }
    }

    static let screenFilename = "screen.mov"
    static let cameraFilename = "camera.mov"
    static let audioFilename = "audio.m4a"
    static let bubbleFilename = "bubble.json"

    static func export(
        project: EditorProject,
        to destination: URL,
        demuxAudio: Bool,
        completion: @escaping (Result<RawExportBundle, Error>) -> Void
    ) {
        let copied: CopyResult
        do {
            copied = try copySourceFiles(project: project, to: destination)
        } catch {
            completion(.failure(error))
            return
        }

        guard demuxAudio else {
            completion(.success(copied.bundle(audioURL: nil)))
            return
        }

        let audioDestination = destination.appendingPathComponent(audioFilename)
        demuxAudioIfPresent(from: copied.screenURL, to: audioDestination) { audioResult in
            switch audioResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(nil):
                // Source had no audio — nothing to strip from the screen copy.
                completion(.success(copied.bundle(audioURL: nil)))
            case .success(let audioURL?):
                // Audio was moved into audio.m4a — re-export screen.mov as
                // video-only so the mic lives in exactly one place.
                stripAudio(from: copied.screenURL) { stripResult in
                    switch stripResult {
                    case .success:
                        completion(.success(copied.bundle(audioURL: audioURL)))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    // MARK: - Copy

    private struct CopyResult {
        let screenURL: URL
        let cameraURL: URL
        let bubbleTimelineURL: URL
        let duration: CMTime

        func bundle(audioURL: URL?) -> RawExportBundle {
            RawExportBundle(
                screenURL: screenURL,
                cameraURL: cameraURL,
                audioURL: audioURL,
                bubbleTimelineURL: bubbleTimelineURL,
                duration: duration)
        }
    }

    private static func copySourceFiles(project: EditorProject,
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

        for url in [project.screenURL, project.cameraURL, project.bubbleTimelineURL] {
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
        try fm.copyItem(at: project.screenURL, to: screenDest)
        try fm.copyItem(at: project.cameraURL, to: cameraDest)
        try fm.copyItem(at: project.bubbleTimelineURL, to: bubbleDest)

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
