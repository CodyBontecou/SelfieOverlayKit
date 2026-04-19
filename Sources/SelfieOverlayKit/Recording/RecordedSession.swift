import Foundation

/// Internal handle to a completed recording's raw tracks on disk. Replaces the
/// old `EditorProject` after the Editor module was removed — now purely a
/// folder + filename convention that the raw-export pipeline hands around.
struct RecordedSession {

    let id: UUID
    let folderURL: URL
    let createdAt: Date

    static let screenFilename = "screen.mov"
    static let cameraFilename = "camera.mov"
    static let bubbleTimelineFilename = "bubble.json"

    var screenURL: URL { folderURL.appendingPathComponent(Self.screenFilename) }
    var cameraURL: URL { folderURL.appendingPathComponent(Self.cameraFilename) }
    var bubbleTimelineURL: URL { folderURL.appendingPathComponent(Self.bubbleTimelineFilename) }
}

/// Creates per-recording folders under
/// `Application Support/SelfieOverlayKit/Sessions/<uuid>/` and handles the
/// small amount of persistence the capture pipeline needs (just the bubble
/// timeline JSON — the raw .movs are moved in by the controller).
struct RecordingStore {

    private let fileManager: FileManager
    let rootURL: URL

    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
            self.rootURL = appSupport
                .appendingPathComponent("SelfieOverlayKit", isDirectory: true)
                .appendingPathComponent("Sessions", isDirectory: true)
        }
        try fileManager.createDirectory(
            at: self.rootURL, withIntermediateDirectories: true)
    }

    func create(id: UUID = UUID(), createdAt: Date = Date()) throws -> RecordedSession {
        let folder = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return RecordedSession(id: id, folderURL: folder, createdAt: createdAt)
    }

    func saveBubbleTimeline(_ timeline: BubbleTimeline,
                            to session: RecordedSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(timeline)
        try data.write(to: session.bubbleTimelineURL, options: .atomic)
    }
}
