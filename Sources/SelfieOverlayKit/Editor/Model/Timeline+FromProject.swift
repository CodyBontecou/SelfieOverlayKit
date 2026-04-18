import AVFoundation
import CoreMedia
import Foundation

public extension Timeline {

    /// Seed a fresh `Timeline` from the raw recordings in an `EditorProject`.
    /// - One video + one optional audio track per screen capture.
    /// - One video track for the selfie camera.
    /// - If the screen `.mov` contains embedded microphone audio, it seeds a
    ///   dedicated `.mic` audio track distinct from the screen audio track.
    ///
    /// The resulting timeline's `duration` clamps to the shortest loaded
    /// asset so preview playback can't run past either source.
    static func fromProject(_ project: EditorProject) -> Timeline {
        return fromAssets(
            screenAsset: AVURLAsset(url: project.screenURL),
            cameraAsset: AVURLAsset(url: project.cameraURL))
    }

    /// Build a `Timeline` directly from asset objects. Exposed for tests and
    /// for callers that already hold decoded assets.
    static func fromAssets(screenAsset: AVAsset, cameraAsset: AVAsset) -> Timeline {
        // AVAsset.duration is deprecated in iOS 16+, but the synchronous
        // accessors still work on iOS 15 and tests avoid the async variant to
        // keep the model layer UI-thread-agnostic.
        let screenDuration = screenAsset.duration
        let cameraDuration = cameraAsset.duration
        let shortest = CMTimeMinimum(screenDuration, cameraDuration)

        var tracks: [Track] = []

        // Screen video
        let screenVideo = Clip.stretched(
            sourceID: .screen,
            sourceRange: CMTimeRange(start: .zero, duration: shortest),
            timelineStart: .zero)
        tracks.append(Track(kind: .video, sourceBinding: .screen, clips: [screenVideo]))

        // Camera video
        let cameraVideo = Clip.stretched(
            sourceID: .camera,
            sourceRange: CMTimeRange(start: .zero, duration: shortest),
            timelineStart: .zero)
        tracks.append(Track(kind: .video, sourceBinding: .camera, clips: [cameraVideo]))

        // Mic audio normally lives in the screen .mov (ReplayKit embeds it
        // there). When screen capture has no audio, the camera .mov carries
        // the mic audio from the AVCaptureSession instead — seed the mic
        // track from whichever asset has audio so "no audio on screen" does
        // not silently drop the mic.
        let screenHasAudio = !screenAsset.tracks(withMediaType: .audio).isEmpty
        let cameraHasAudio = !cameraAsset.tracks(withMediaType: .audio).isEmpty
        if screenHasAudio || cameraHasAudio {
            let micClip = Clip.stretched(
                sourceID: .mic,
                sourceRange: CMTimeRange(start: .zero, duration: shortest),
                timelineStart: .zero)
            tracks.append(Track(kind: .audio, sourceBinding: .mic, clips: [micClip]))
        }

        return Timeline(tracks: tracks, duration: shortest)
    }
}
