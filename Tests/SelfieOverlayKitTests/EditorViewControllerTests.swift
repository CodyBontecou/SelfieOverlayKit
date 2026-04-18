import AVFoundation
import CoreMedia
import UIKit
import XCTest
@testable import SelfieOverlayKit

final class EditorViewControllerTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("EditorViewControllerTests-\(UUID().uuidString)", isDirectory: true)
        store = try ProjectStore(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: 600)
    }

    private func makeProject(duration: CMTime = CMTime(seconds: 1, preferredTimescale: 600)) throws -> EditorProject {
        let project = try store.create()
        try TestVideoFixtures.writeBlackMOV(
            to: project.screenURL, duration: duration, color: (255, 0, 0))
        try TestVideoFixtures.writeBlackMOV(
            to: project.cameraURL, duration: duration, color: (0, 255, 0))
        try store.saveBubbleTimeline(BubbleTimeline(snapshots: []), to: project)
        try store.saveMetadata(project)
        return project
    }

    // MARK: - AC: ExportPreviewViewController.swift no longer exists in the tree

    func testExportPreviewViewControllerSourceRemoved() {
        let project = Bundle(for: Self.self).bundlePath
        XCTAssertFalse(project.contains("ExportPreviewViewController"),
                       "sanity: test bundle should not reference removed file by name")
        // Source-level check: the type cannot resolve via NSClassFromString.
        XCTAssertNil(NSClassFromString("SelfieOverlayKit.ExportPreviewViewController"))
    }

    // MARK: - AC: viewDidLoad wires up the expected hierarchy

    func testViewHierarchyContainsPreviewAndControls() throws {
        let project = try makeProject()
        let vc = try EditorViewController(project: project, projectStore: store)
        vc.loadViewIfNeeded()

        XCTAssertNotNil(vc.view.subviews.first(where: { $0 is PreviewCanvasView }),
                        "preview canvas must be in the view hierarchy")

        XCTAssertEqual(vc.navigationItem.leftBarButtonItem?.title, "Discard")
        XCTAssertEqual(vc.navigationItem.rightBarButtonItems?.count, 2)
        XCTAssertEqual(vc.navigationItem.rightBarButtonItems?.first?.title, "Save")
    }

    // MARK: - AC: discard deletes the project folder

    func testDiscardDeletesProjectFolder() throws {
        let project = try makeProject()
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.folderURL.path))

        let vc = try EditorViewController(project: project, projectStore: store)
        vc.loadViewIfNeeded()

        // performDiscard calls dismiss(animated:). Without a presenting stack
        // the dismiss is a no-op, but the projectStore.delete call still
        // happens — and that is the AC we care about.
        vc.performDiscard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: project.folderURL.path))
    }

    // MARK: - AC: hardware keyboard shortcuts are wired up

    func testKeyCommandsExposeCoreEditorShortcuts() throws {
        let project = try makeProject()
        let vc = try EditorViewController(project: project, projectStore: store)
        vc.loadViewIfNeeded()

        let commands = try XCTUnwrap(vc.keyCommands)
        func match(_ input: String, _ flags: UIKeyModifierFlags) -> UIKeyCommand? {
            commands.first { $0.input == input && $0.modifierFlags == flags }
        }
        XCTAssertNotNil(match(" ", []), "space must be bound for play/pause")
        XCTAssertNotNil(match("z", .command), "cmd-z must be bound for undo")
        XCTAssertNotNil(match("z", [.command, .shift]), "cmd-shift-z must be bound for redo")
        XCTAssertNotNil(match("b", .command), "cmd-b must be bound for split")
        XCTAssertNotNil(match("s", []), "s must be bound for split")
        XCTAssertNotNil(match(UIKeyCommand.inputLeftArrow, []), "left arrow must nudge")
        XCTAssertNotNil(match(UIKeyCommand.inputRightArrow, []), "right arrow must nudge")
        XCTAssertNotNil(match(UIKeyCommand.inputLeftArrow, .alternate),
                        "opt-left must nudge by a frame")
        XCTAssertNotNil(match("\u{8}", []), "backspace must delete selected clip")
    }

    // MARK: - AC: minimal export produces a readable MP4

    func testExportToTempFileProducesPlayableMP4() throws {
        let project = try makeProject(duration: t(1))
        let vc = try EditorViewController(project: project, projectStore: store)
        vc.loadViewIfNeeded()

        let done = expectation(description: "export completes")
        var exported: URL?
        vc.exportToTempFile { result in
            if case .success(let url) = result { exported = url }
            done.fulfill()
        }
        wait(for: [done], timeout: 30.0)

        let url = try XCTUnwrap(exported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let asset = AVURLAsset(url: url)
        XCTAssertGreaterThan(asset.duration.seconds, 0.5)
        try? FileManager.default.removeItem(at: url)
    }
}
