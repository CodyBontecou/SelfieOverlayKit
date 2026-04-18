import CoreMedia
import Foundation

/// Codable conformance for the edit model. `CMTime` and `CMTimeRange` are C
/// structs and have no synthesized Codable, so each wrapper maps to a
/// `{value, timescale}` / `{start, duration}` JSON object. Encoding keeps
/// the source timescale intact — we deliberately don't collapse to
/// `Double(seconds)` because AVMutableComposition is sensitive to timescale
/// (see the ns-scale scaleTimeRange hang in CompositionBuilder).

extension Timeline: Codable {

    enum CodingKeys: String, CodingKey { case tracks, duration }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tracks = try c.decode([Track].self, forKey: .tracks)
        let duration = try c.decode(CodableCMTime.self, forKey: .duration).cmTime
        self.init(tracks: tracks, duration: duration)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(CodableCMTime(duration), forKey: .duration)
    }
}

extension Track: Codable {

    enum CodingKeys: String, CodingKey { case id, kind, sourceBinding, clips }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            kind: try c.decode(Kind.self, forKey: .kind),
            sourceBinding: try c.decode(SourceID.self, forKey: .sourceBinding),
            clips: try c.decode([Clip].self, forKey: .clips))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(sourceBinding, forKey: .sourceBinding)
        try c.encode(clips, forKey: .clips)
    }
}

extension Clip: Codable {

    enum CodingKeys: String, CodingKey {
        case id, sourceID, sourceRange, timelineRange, speed, volume
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            sourceID: try c.decode(SourceID.self, forKey: .sourceID),
            sourceRange: try c.decode(CodableCMTimeRange.self, forKey: .sourceRange).cmTimeRange,
            timelineRange: try c.decode(CodableCMTimeRange.self, forKey: .timelineRange).cmTimeRange,
            speed: try c.decode(Double.self, forKey: .speed),
            volume: try c.decode(Float.self, forKey: .volume))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(CodableCMTimeRange(sourceRange), forKey: .sourceRange)
        try c.encode(CodableCMTimeRange(timelineRange), forKey: .timelineRange)
        try c.encode(speed, forKey: .speed)
        try c.encode(volume, forKey: .volume)
    }
}

struct CodableCMTime: Codable {
    let value: Int64
    let timescale: Int32

    init(_ time: CMTime) {
        self.value = time.value
        self.timescale = time.timescale
    }

    var cmTime: CMTime {
        CMTime(value: CMTimeValue(value), timescale: CMTimeScale(timescale))
    }
}

struct CodableCMTimeRange: Codable {
    let start: CodableCMTime
    let duration: CodableCMTime

    init(_ range: CMTimeRange) {
        self.start = CodableCMTime(range.start)
        self.duration = CodableCMTime(range.duration)
    }

    var cmTimeRange: CMTimeRange {
        CMTimeRange(start: start.cmTime, duration: duration.cmTime)
    }
}
