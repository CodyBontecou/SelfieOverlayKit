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

    public static func build(timeline: Timeline, project: EditorProject) -> Output {
        build(
            timeline: timeline,
            screenAsset: AVURLAsset(url: project.screenURL),
            cameraAsset: AVURLAsset(url: project.cameraURL))
    }

    /// Asset-level entry point. Exposed so tests can build compositions from
    /// synthetic assets without roundtripping through a `ProjectStore`.
    public static func build(timeline: Timeline,
                             screenAsset: AVAsset,
                             cameraAsset: AVAsset) -> Output {
        let composition = AVMutableComposition()

        let sourceVideo: [SourceID: AVAssetTrack] = [
            .screen: screenAsset.tracks(withMediaType: .video).first,
            .camera: cameraAsset.tracks(withMediaType: .video).first
        ].compactMapValues { $0 }

        let sourceAudio: [SourceID: AVAssetTrack] = [
            .screen: screenAsset.tracks(withMediaType: .audio).first,
            .camera: cameraAsset.tracks(withMediaType: .audio).first,
            .mic: screenAsset.tracks(withMediaType: .audio).first
        ].compactMapValues { $0 }

        var audioMixParams: [AVMutableAudioMixInputParameters] = []

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

            for clip in track.clips {
                insertAndScale(clip: clip, into: compTrack, from: sourceTrack)
            }

            if track.kind == .audio {
                audioMixParams.append(makeAudioParams(for: compTrack, clips: track.clips))
            }
        }

        let videoComposition = makePassthroughVideoComposition(
            for: composition,
            duration: timeline.duration,
            preferredFrameRate: sourceVideo[.screen]?.nominalFrameRate)

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioMixParams

        return Output(composition: composition,
                      videoComposition: videoComposition,
                      audioMix: audioMix)
    }

    // MARK: - Helpers

    private static func insertAndScale(clip: Clip,
                                       into compTrack: AVMutableCompositionTrack,
                                       from sourceTrack: AVAssetTrack) {
        do {
            try compTrack.insertTimeRange(
                clip.sourceRange,
                of: sourceTrack,
                at: clip.timelineRange.start)
        } catch {
            return
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

    private static func makePassthroughVideoComposition(
        for composition: AVMutableComposition,
        duration: CMTime,
        preferredFrameRate: Float?
    ) -> AVMutableVideoComposition {
        let video = AVMutableVideoComposition()
        let fps = preferredFrameRate.map { Double($0) } ?? 30
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))

        let videoTracks = composition.tracks(withMediaType: .video)
        video.renderSize = videoTracks.first?.naturalSize ?? CGSize(width: 1080, height: 1920)

        // Single pass-through instruction spanning the timeline.
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
            start: .zero,
            duration: duration == .zero ? composition.duration : duration)
        instruction.layerInstructions = videoTracks.map {
            AVMutableVideoCompositionLayerInstruction(assetTrack: $0)
        }
        video.instructions = [instruction]
        return video
    }
}
