import AVFoundation
import CoreMedia
import Foundation

/// Translates a pure `Timeline` + `EditorProject` into the AVFoundation
/// trio that powers both playback and export: `AVMutableComposition`,
/// `AVMutableVideoComposition`, and `AVAudioMix`.
///
/// Behavior in this iteration:
/// - Each `Clip.sourceRange` is inserted at `Clip.timelineRange.start` on
///   a dedicated composition track.
/// - Non-unit `speed` is applied via `scaleTimeRange(_:toDuration:)` on
///   each inserted segment. Video and audio clips from the same source
///   scale in lockstep as long as the caller sets matching speeds on
///   both clips (enforced by T12's speed control, not here).
/// - Audio clips feed `AVMutableAudioMixInputParameters` entries with a
///   volume keyframe at the clip's timeline start and the
///   `spectral` pitch algorithm so speed changes preserve pitch.
/// - `videoComposition` is a pass-through — T5 swaps in the
///   bubble-aware custom compositor.
public enum CompositionBuilder {

    public struct Output {
        public let composition: AVMutableComposition
        public let videoComposition: AVMutableVideoComposition
        public let audioMix: AVMutableAudioMix
    }

    public enum BuildError: LocalizedError {
        case insertFailed(clipID: UUID, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .insertFailed(_, let underlying):
                return "Failed to assemble clip: \(underlying.localizedDescription)"
            }
        }
    }

    static func build(timeline: Timeline,
                      project: EditorProject,
                      bubbleTimeline: BubbleTimeline? = nil,
                      screenScale: CGFloat = 1) throws -> Output {
        try build(
            timeline: timeline,
            screenAsset: AVURLAsset(url: project.screenURL),
            cameraAsset: AVURLAsset(url: project.cameraURL),
            bubbleTimeline: bubbleTimeline,
            screenScale: screenScale)
    }

    /// Asset-level entry point. Exposed so tests can build compositions from
    /// synthetic assets without roundtripping through a `ProjectStore`.
    static func build(timeline: Timeline,
                      screenAsset: AVAsset,
                      cameraAsset: AVAsset,
                      bubbleTimeline: BubbleTimeline? = nil,
                      screenScale: CGFloat = 1) throws -> Output {
        let composition = AVMutableComposition()

        let sourceVideo: [SourceID: AVAssetTrack] = [
            .screen: screenAsset.tracks(withMediaType: .video).first,
            .camera: cameraAsset.tracks(withMediaType: .video).first
        ].compactMapValues { $0 }

        // ReplayKit normally embeds mic audio in the screen .mov, so .mic
        // defaults to that track. When the screen capture has no audio (mic
        // was denied, or the session is screen-only) the camera .mov still
        // carries mic audio from the AVCaptureSession, so fall back there
        // rather than silently dropping the mic track.
        let sourceAudio: [SourceID: AVAssetTrack] = [
            .screen: screenAsset.tracks(withMediaType: .audio).first,
            .camera: cameraAsset.tracks(withMediaType: .audio).first,
            .mic: screenAsset.tracks(withMediaType: .audio).first
                ?? cameraAsset.tracks(withMediaType: .audio).first
        ].compactMapValues { $0 }

        var audioMixParams: [AVMutableAudioMixInputParameters] = []
        // Per-source-binding track IDs — startRequest uses these to pull
        // the right source frame for the bubble compositor's instruction.
        var videoTrackIDs: [SourceID: CMPersistentTrackID] = [:]
        var screenClips: [Clip] = []
        var cameraClips: [Clip] = []

        for track in timeline.tracks {
            let sourceTrack: AVAssetTrack?
            switch track.kind {
            case .video: sourceTrack = sourceVideo[track.sourceBinding]
            case .audio: sourceTrack = sourceAudio[track.sourceBinding]
            }
            guard let sourceTrack else { continue }

            guard let compTrack = composition.addMutableTrack(
                withMediaType: track.kind == .video ? .video : .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            if track.kind == .video {
                videoTrackIDs[track.sourceBinding] = compTrack.trackID
                if track.sourceBinding == .screen {
                    screenClips = track.clips
                }
                if track.sourceBinding == .camera {
                    cameraClips = track.clips
                }
            }

            for clip in track.clips {
                try insertAndScale(clip: clip, into: compTrack, from: sourceTrack)
            }

            if track.kind == .audio {
                audioMixParams.append(makeAudioParams(for: compTrack, clips: track.clips))
            }
        }

        // Composition-level backstop for older projects recorded before the
        // capture-time 30 fps lock landed: pick the higher of screen/camera
        // so the slower stream duplicates frames against the faster one
        // rather than the faster stream getting decimated. See
        // ios-selfie-sdk-rfl.
        let screenFPS = sourceVideo[.screen]?.nominalFrameRate
        let cameraFPS = sourceVideo[.camera]?.nominalFrameRate
        let preferredFPS = [screenFPS, cameraFPS].compactMap { $0 }.max()
        let videoComposition = makeBubbleVideoComposition(
            for: composition,
            screenClips: screenClips,
            cameraClips: cameraClips,
            screenTrackID: videoTrackIDs[.screen] ?? kCMPersistentTrackID_Invalid,
            cameraTrackID: videoTrackIDs[.camera],
            bubbleTimeline: bubbleTimeline,
            screenScale: screenScale,
            duration: timeline.duration,
            preferredFrameRate: preferredFPS)

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioMixParams

        return Output(composition: composition,
                      videoComposition: videoComposition,
                      audioMix: audioMix)
    }

    // MARK: - Helpers

    private static func insertAndScale(clip: Clip,
                                       into compTrack: AVMutableCompositionTrack,
                                       from sourceTrack: AVAssetTrack) throws {
        do {
            try compTrack.insertTimeRange(
                clip.sourceRange,
                of: sourceTrack,
                at: clip.timelineRange.start)
        } catch {
            throw BuildError.insertFailed(clipID: clip.id, underlying: error)
        }

        guard clip.speed != 1.0 else { return }
        // The segment just inserted occupies
        // [timelineRange.start, timelineRange.start + sourceRange.duration).
        // scaleTimeRange retimes that span to the clip's timelineRange
        // duration, which — at the same speed on the paired audio clip —
        // keeps A/V locked. Convert the target duration to the source
        // track's native timescale first; passing a ns-scale CMTime was
        // observed to hang scaleTimeRange on the simulator.
        let insertedRange = CMTimeRange(
            start: clip.timelineRange.start,
            duration: clip.sourceRange.duration)
        let targetDuration = CMTimeConvertScale(
            clip.timelineRange.duration,
            timescale: sourceTrack.naturalTimeScale,
            method: .default)
        compTrack.scaleTimeRange(insertedRange, toDuration: targetDuration)
    }

    private static func makeAudioParams(for compTrack: AVMutableCompositionTrack,
                                        clips: [Clip]) -> AVMutableAudioMixInputParameters {
        let params = AVMutableAudioMixInputParameters(track: compTrack)
        params.audioTimePitchAlgorithm = .spectral
        for clip in clips {
            params.setVolume(clip.volume, at: clip.timelineRange.start)
        }
        return params
    }

    private static func makeBubbleVideoComposition(
        for composition: AVMutableComposition,
        screenClips: [Clip],
        cameraClips: [Clip],
        screenTrackID: CMPersistentTrackID,
        cameraTrackID: CMPersistentTrackID?,
        bubbleTimeline: BubbleTimeline?,
        screenScale: CGFloat,
        duration: CMTime,
        preferredFrameRate: Float?
    ) -> AVMutableVideoComposition {
        let video = AVMutableVideoComposition()
        let fps = preferredFrameRate.map { Double($0) } ?? 30
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))

        let renderSize = composition.tracks(withMediaType: .video).first?.naturalSize
            ?? CGSize(width: 1080, height: 1920)
        video.renderSize = renderSize
        video.customVideoCompositorClass = BubbleVideoCompositor.self

        // Tag output as BT.709 SDR. Capture sources (ReplayKit, camera) are
        // 8-bit BT.709 today; any wide-color input is tone-mapped to SDR on
        // the way through the BGRA compositor. Explicit tags keep the output
        // color deterministic on the sharing paths that matter (social/IM),
        // which re-encode to SDR anyway.
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let totalDuration = duration == .zero ? composition.duration : duration

        var instructions: [AVVideoCompositionInstructionProtocol] = []
        if screenClips.isEmpty {
            // No screen track — emit one full-span instruction so AVFoundation
            // still has something to drive playback with. Grab the first
            // camera clip for its transform, if any.
            let cameraClip = cameraClips.first
            instructions.append(BubbleCompositionInstruction(
                timeRange: CMTimeRange(start: .zero, duration: totalDuration),
                screenTrackID: screenTrackID,
                cameraTrackID: cameraTrackID,
                bubbleTimeline: bubbleTimeline,
                sourceStart: .zero,
                speed: 1.0,
                screenScale: screenScale,
                outputSize: renderSize,
                screenTransform: .identity,
                cameraTransform: cameraClip.map(layerTransform(from:)) ?? .identity,
                cameraShapeOverride: cameraClip?.cameraShape))
        } else {
            for clip in screenClips {
                // Camera clip that overlaps this screen-clip's time range.
                // Clips on the same track don't overlap by construction so
                // the first match is the only one. Still guard with
                // `nonEmpty` intersection so a zero-length sliver isn't
                // picked as the owner.
                let cameraClip = cameraClips.first { camera in
                    let intersection = clip.timelineRange.intersection(camera.timelineRange)
                    return !intersection.isEmpty && intersection.duration > .zero
                }
                instructions.append(BubbleCompositionInstruction(
                    timeRange: clip.timelineRange,
                    screenTrackID: screenTrackID,
                    cameraTrackID: cameraTrackID,
                    bubbleTimeline: bubbleTimeline,
                    sourceStart: clip.sourceRange.start,
                    speed: clip.speed,
                    screenScale: screenScale,
                    outputSize: renderSize,
                    screenTransform: layerTransform(from: clip),
                    cameraTransform: cameraClip.map(layerTransform(from:)) ?? .identity,
                    cameraShapeOverride: cameraClip?.cameraShape))
            }
        }
        video.instructions = instructions
        return video
    }

    private static func layerTransform(from clip: Clip) -> BubbleOverlayRenderer.LayerTransform {
        BubbleOverlayRenderer.LayerTransform(
            cropRect: clip.cropRect,
            scale: clip.canvasScale,
            offset: clip.canvasOffset)
    }
}
