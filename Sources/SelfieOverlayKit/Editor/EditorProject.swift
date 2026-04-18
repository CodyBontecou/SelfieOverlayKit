import Foundation

/// Persistent handle to a recorded session's raw tracks + bubble timeline.
///
/// The editor works by holding onto the untouched ReplayKit screen capture,
/// the raw camera `.mov`, and the sampled `BubbleTimeline` side by side in a
/// project folder under `Application Support/SelfieOverlayKit/Projects/<uuid>/`.
/// Compositing happens only at preview / export time, so users can edit each
/// layer independently.
///
/// `folderURL` is not encoded; callers that decode an `EditorProject` must
/// provide the containing folder via `decoder.userInfo[folderURLUserInfoKey]`.
/// `ProjectStore` handles this in practice.
struct EditorProject: Codable, Equatable {

    let id: UUID
    let createdAt: Date
    var folderURL: URL

    static let screenFilename = "screen.mov"
    static let cameraFilename = "camera.mov"
    static let bubbleTimelineFilename = "bubble.json"
    static let metadataFilename = "project.json"

    var screenURL: URL { folderURL.appendingPathComponent(Self.screenFilename) }
    var cameraURL: URL { folderURL.appendingPathComponent(Self.cameraFilename) }
    var bubbleTimelineURL: URL { folderURL.appendingPathComponent(Self.bubbleTimelineFilename) }
    var metadataURL: URL { folderURL.appendingPathComponent(Self.metadataFilename) }

    /// Pass the containing folder into a `JSONDecoder` via this key so
    /// `EditorProject.init(from:)` can rebuild `folderURL` without the
    /// encoded JSON embedding fragile absolute paths.
    static let folderURLUserInfoKey = CodingUserInfoKey(rawValue: "EditorProject.folderURL")!

    init(id: UUID = UUID(), folderURL: URL, createdAt: Date = Date()) {
        self.id = id
        self.folderURL = folderURL
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        guard let folder = decoder.userInfo[Self.folderURLUserInfoKey] as? URL else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "EditorProject decoding requires userInfo[folderURLUserInfoKey]"))
        }
        self.folderURL = folder
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
    }
}
