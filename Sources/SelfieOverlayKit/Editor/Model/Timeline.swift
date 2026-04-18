import CoreMedia
import Foundation

/// Value-type edit model: an ordered collection of tracks with a total
/// duration. All mutations return a new `Timeline`, so the editor can diff
/// versions for undo / redo and derive compositions without mutating state.
public struct Timeline: Hashable {

    public enum TrimEdge: String, Hashable {
        case start
        case end
    }

    public var tracks: [Track]
    public var duration: CMTime

    public init(tracks: [Track] = [], duration: CMTime = .zero) {
        self.tracks = tracks
        self.duration = duration
    }

    // MARK: - Lookups

    /// Find the track + clip index for a given clip id.
    public func locate(clipID: UUID) -> (trackIndex: Int, clipIndex: Int)? {
        for (ti, track) in tracks.enumerated() {
            if let ci = track.clips.firstIndex(where: { $0.id == clipID }) {
                return (ti, ci)
            }
        }
        return nil
    }

    // MARK: - Pure mutations

    public func inserting(_ clip: Clip, onTrackID trackID: UUID) -> Timeline {
        var copy = self
        guard let ti = copy.tracks.firstIndex(where: { $0.id == trackID }) else { return self }
        copy.tracks[ti].clips.append(clip)
        copy.tracks[ti].clips.sort { $0.timelineRange.start < $1.timelineRange.start }
        return copy
    }

    public func removing(clipID: UUID) -> Timeline {
        guard let loc = locate(clipID: clipID) else { return self }
        var copy = self
        copy.tracks[loc.trackIndex].clips.remove(at: loc.clipIndex)
        return copy
    }

    /// Apply a new speed to the clip *and* to every overlapping audio clip
    /// on other audio tracks, so paired video + audio stay in lockstep.
    /// A single call bundles everything into one undo step.
    public func settingPairedSpeed(clipID: UUID, _ speed: Double) -> Timeline {
        guard let loc = locate(clipID: clipID) else { return self }
        let originalRange = tracks[loc.trackIndex].clips[loc.clipIndex].timelineRange
        let originalKind = tracks[loc.trackIndex].kind
        var copy = self.settingSpeed(clipID: clipID, speed)

        // Only re-pair when the user retimes a video clip — audio-only retimes
        // don't imply any video counterpart.
        guard originalKind == .video else { return copy }
        for track in tracks where track.kind == .audio {
            for clip in track.clips where overlaps(clip.timelineRange, originalRange) {
                copy = copy.settingSpeed(clipID: clip.id, speed)
            }
        }
        return copy
    }

    private func overlaps(_ a: CMTimeRange, _ b: CMTimeRange) -> Bool {
        let intersection = a.intersection(b)
        return !intersection.isEmpty && intersection.duration > .zero
    }

    public func settingSpeed(clipID: UUID, _ speed: Double) -> Timeline {
        precondition(speed > 0, "speed must be positive")
        guard let loc = locate(clipID: clipID) else { return self }
        var copy = self
        var clip = copy.tracks[loc.trackIndex].clips[loc.clipIndex]
        // Hold timelineRange.start fixed; scale timelineRange.duration to the
        // new speed so paired audio / video tracks can be re-timed in lockstep.
        // Round to the source timescale — CMTimeMultiplyByFloat64 returns a
        // ns-scale time that AVMutableCompositionTrack.scaleTimeRange does
        // not align well with, leading to hangs on simulator.
        let newTimelineDuration = CMTimeMultiplyByFloat64(clip.sourceRange.duration, multiplier: 1.0 / speed)
        let rounded = CMTimeConvertScale(newTimelineDuration,
                                         timescale: clip.sourceRange.duration.timescale,
                                         method: .default)
        clip.speed = speed
        clip.timelineRange = CMTimeRange(start: clip.timelineRange.start, duration: rounded)
        copy.tracks[loc.trackIndex].clips[loc.clipIndex] = clip
        return copy
    }

    /// Clip volume range — unity at 1.0, up to 2.0 for amplification. The
    /// inspector UI (T13) surfaces this as a 0%–200% slider; AVAudioMix
    /// accepts values beyond 1.0 so we don't saturate at unity.
    public static let volumeRange: ClosedRange<Float> = 0.0...2.0

    public func settingVolume(clipID: UUID, _ volume: Float) -> Timeline {
        guard let loc = locate(clipID: clipID) else { return self }
        var copy = self
        let clamped = min(max(Timeline.volumeRange.lowerBound, volume),
                          Timeline.volumeRange.upperBound)
        copy.tracks[loc.trackIndex].clips[loc.clipIndex].volume = clamped
        return copy
    }

    /// Trim the given edge of a clip. `newSourceRange` defines the updated
    /// slice of the source asset. The other edge stays anchored on the
    /// timeline (non-ripple trim); the trimmed edge moves so the timelineRange
    /// scales with the new source duration at the clip's current speed.
    public func trimming(clipID: UUID, edge: TrimEdge, newSourceRange: CMTimeRange) -> Timeline {
        guard let loc = locate(clipID: clipID) else { return self }
        var copy = self
        var clip = copy.tracks[loc.trackIndex].clips[loc.clipIndex]
        let rawTimelineDuration = CMTimeMultiplyByFloat64(newSourceRange.duration, multiplier: 1.0 / clip.speed)
        let newTimelineDuration = CMTimeConvertScale(rawTimelineDuration,
                                                     timescale: newSourceRange.duration.timescale,
                                                     method: .default)
        switch edge {
        case .start:
            // Right edge anchored; shift the start so end stays put.
            let oldEnd = clip.timelineRange.end
            let newStart = oldEnd - newTimelineDuration
            clip.timelineRange = CMTimeRange(start: newStart, duration: newTimelineDuration)
        case .end:
            // Left edge anchored.
            clip.timelineRange = CMTimeRange(start: clip.timelineRange.start, duration: newTimelineDuration)
        }
        clip.sourceRange = newSourceRange
        copy.tracks[loc.trackIndex].clips[loc.clipIndex] = clip
        return copy
    }

    /// Split whichever clip on the given track contains the timeline time `at`.
    /// The two halves share the original speed and volume.
    ///
    /// When `t` lands exactly on a clip edge that is NOT a shared seam between
    /// two adjacent clips, the split point is snapped one tick inside the
    /// clip so the user gets visible feedback instead of a silent no-op.
    public func splitting(at t: CMTime, trackID: UUID) -> Timeline {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else { return self }
        let clips = tracks[ti].clips

        var effectiveT = t
        var clipIndex = clips.firstIndex(where: {
            t > $0.timelineRange.start && t < $0.timelineRange.end
        })

        if clipIndex == nil {
            let hasAdjacentStart = clips.contains(where: { $0.timelineRange.start == t })
            let hasAdjacentEnd = clips.contains(where: { $0.timelineRange.end == t })
            let atSeam = hasAdjacentStart && hasAdjacentEnd
            if !atSeam {
                if let ci = clips.firstIndex(where: { $0.timelineRange.start == t }) {
                    let clip = clips[ci]
                    let tick = CMTime(value: 1, timescale: clip.timelineRange.duration.timescale)
                    let snapped = clip.timelineRange.start + tick
                    if snapped < clip.timelineRange.end {
                        effectiveT = snapped
                        clipIndex = ci
                    }
                } else if let ci = clips.firstIndex(where: { $0.timelineRange.end == t }) {
                    let clip = clips[ci]
                    let tick = CMTime(value: 1, timescale: clip.timelineRange.duration.timescale)
                    let snapped = clip.timelineRange.end - tick
                    if snapped > clip.timelineRange.start {
                        effectiveT = snapped
                        clipIndex = ci
                    }
                }
            }
        }

        guard let ci = clipIndex else { return self }
        let clip = clips[ci]
        let timelineOffset = effectiveT - clip.timelineRange.start
        let sourceOffset = CMTimeMultiplyByFloat64(timelineOffset, multiplier: clip.speed)
        let splitSourceTime = clip.sourceRange.start + sourceOffset

        let left = Clip(
            id: UUID(),
            sourceID: clip.sourceID,
            sourceRange: CMTimeRange(start: clip.sourceRange.start, end: splitSourceTime),
            timelineRange: CMTimeRange(start: clip.timelineRange.start, end: effectiveT),
            speed: clip.speed,
            volume: clip.volume)
        let right = Clip(
            id: UUID(),
            sourceID: clip.sourceID,
            sourceRange: CMTimeRange(start: splitSourceTime, end: clip.sourceRange.end),
            timelineRange: CMTimeRange(start: effectiveT, end: clip.timelineRange.end),
            speed: clip.speed,
            volume: clip.volume)

        var copy = self
        copy.tracks[ti].clips.replaceSubrange(ci...ci, with: [left, right])
        return copy
    }
}
