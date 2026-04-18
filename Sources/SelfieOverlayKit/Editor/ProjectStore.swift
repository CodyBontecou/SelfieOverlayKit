import Foundation

/// Creates and loads `EditorProject`s under
/// `Application Support/SelfieOverlayKit/Projects/<uuid>/`.
final class ProjectStore {

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
                .appendingPathComponent("Projects", isDirectory: true)
        }
        try fileManager.createDirectory(
            at: self.rootURL, withIntermediateDirectories: true)
    }

    /// Build an empty project folder on disk and return a handle. The caller is
    /// responsible for populating `screenURL`, `cameraURL`, and
    /// `bubbleTimelineURL` and calling `saveMetadata(_:)` when ready.
    func create(id: UUID = UUID(), createdAt: Date = Date()) throws -> EditorProject {
        let folder = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return EditorProject(id: id, folderURL: folder, createdAt: createdAt)
    }

    /// Persist the project's metadata JSON so it can be reloaded later.
    func saveMetadata(_ project: EditorProject) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        try data.write(to: project.metadataURL, options: .atomic)
    }

    /// Write a `BubbleTimeline` to the project's canonical bubble JSON path.
    func saveBubbleTimeline(_ timeline: BubbleTimeline, to project: EditorProject) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(timeline)
        try data.write(to: project.bubbleTimelineURL, options: .atomic)
    }

    /// Load a previously persisted project by id.
    func load(id: UUID) throws -> EditorProject {
        let folder = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let metadataURL = folder.appendingPathComponent(EditorProject.metadataFilename)
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[EditorProject.folderURLUserInfoKey] = folder
        return try decoder.decode(EditorProject.self, from: data)
    }

    /// Load the `BubbleTimeline` saved alongside the given project.
    func loadBubbleTimeline(for project: EditorProject) throws -> BubbleTimeline {
        let data = try Data(contentsOf: project.bubbleTimelineURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BubbleTimeline.self, from: data)
    }

    /// Delete a project folder and every file inside it.
    func delete(_ project: EditorProject) throws {
        try fileManager.removeItem(at: project.folderURL)
    }
}
