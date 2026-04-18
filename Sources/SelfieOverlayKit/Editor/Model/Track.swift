import Foundation

/// An ordered lane of `Clip`s. Video and audio clips live on separate tracks
/// so the editor can mute or re-time audio independently of its paired video.
public struct Track: Identifiable, Hashable {

    public enum Kind: String, Codable, Hashable {
        case video
        case audio
    }

    public let id: UUID
    public var kind: Kind
    /// Which source this track draws from by default. A single screen or
    /// camera source can back multiple tracks (e.g. one video, one audio).
    public var sourceBinding: SourceID
    public var clips: [Clip]

    public init(id: UUID = UUID(),
                kind: Kind,
                sourceBinding: SourceID,
                clips: [Clip] = []) {
        self.id = id
        self.kind = kind
        self.sourceBinding = sourceBinding
        self.clips = clips
    }
}
