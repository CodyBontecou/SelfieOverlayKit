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

    public func settingSpeed(clipID: UUID, _ speed: Double) -> Timeline {
        precondition(speed > 0, "speed must be positive")
        guard let loc = locate(clipID: clipID) else { return self }
        var copy = self
        var clip = copy.tracks[loc.trackIndex].clips[loc.clipIndex]
        // Hold timelineRange.start fixed; scale timelineRange.duration to the
        // new speed so paired audio / video tracks can be re-timed in lockstep.
        let newTimelineDuration = CMTimeMultiplyByFloat64(clip.sourceRange.duration, multiplier: 1.0 / speed)
        clip.speed = speed
        clip.timelineRange = CMTimeRange(start: clip.timelineRange.start, duration: newTimelineDuration)
        copy.tracks[loc.trackIndex].clips[loc.clipIndex] = clip
        return copy
    }

    public func settingVolume(clipID: UUID, _ volume: Float) -> Timeline {
        guard let loc = locate(clipID: clipID) else { return self }
        var copy = self
        copy.tracks[loc.trackIndex].clips[loc.clipIndex].volume = max(0, min(1, volume))
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
        let newTimelineDuration = CMTimeMultiplyByFloat64(newSourceRange.duration, multiplier: 1.0 / clip.speed)
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
    public func splitting(at t: CMTime, trackID: UUID) -> Timeline {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else { return self }
        guard let ci = tracks[ti].clips.firstIndex(where: {
            t > $0.timelineRange.start && t < $0.timelineRange.end
        }) else { return self }

        let clip = tracks[ti].clips[ci]
        let timelineOffset = t - clip.timelineRange.start                 // before split, timeline time into the clip
        let sourceOffset = CMTimeMultiplyByFloat64(timelineOffset, multiplier: clip.speed)
        let splitSourceTime = clip.sourceRange.start + sourceOffset

        let left = Clip(
            id: UUID(),
            sourceID: clip.sourceID,
            sourceRange: CMTimeRange(start: clip.sourceRange.start, end: splitSourceTime),
            timelineRange: CMTimeRange(start: clip.timelineRange.start, end: t),
            speed: clip.speed,
            volume: clip.volume)
        let right = Clip(
            id: UUID(),
            sourceID: clip.sourceID,
            sourceRange: CMTimeRange(start: splitSourceTime, end: clip.sourceRange.end),
            timelineRange: CMTimeRange(start: t, end: clip.timelineRange.end),
            speed: clip.speed,
            volume: clip.volume)

        var copy = self
        copy.tracks[ti].clips.replaceSubrange(ci...ci, with: [left, right])
        return copy
    }
}
