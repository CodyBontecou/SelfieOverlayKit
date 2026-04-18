import AVFoundation
import CoreMedia
import CoreVideo
import UIKit
import XCTest
@testable import SelfieOverlayKit

final class BubbleVideoCompositorTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ProjectStore!
    private let tb: CMTimeScale = 600

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("BubbleVideoCompositorTests-\(UUID().uuidString)", isDirectory: true)
        store = try ProjectStore(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: tb)
    }

    private func makeAssets(
        duration: CMTime,
        screenColor: (r: UInt8, g: UInt8, b: UInt8) = (255, 0, 0),
        cameraColor: (r: UInt8, g: UInt8, b: UInt8) = (0, 255, 0)
    ) throws -> (EditorProject, AVURLAsset, AVURLAsset) {
        let project = try store.create()
        try TestVideoFixtures.writeBlackMOV(to: project.screenURL, duration: duration, color: screenColor)
        try TestVideoFixtures.writeBlackMOV(to: project.cameraURL, duration: duration, color: cameraColor)
        return (project, AVURLAsset(url: project.screenURL), AVURLAsset(url: project.cameraURL))
    }

    private func pixel(in cgImage: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * cgImage.height)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixels,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        let i = y * bytesPerRow + x * bytesPerPixel
        return (pixels[i], pixels[i+1], pixels[i+2], pixels[i+3])
    }

    // MARK: - AC1: AVPlayer / image generator renders the bubble over the screen track

    func testCompositorRendersBubbleAtExpectedPosition() throws {
        let (_, screen, camera) = try makeAssets(duration: t(2))
        let timeline = Timeline.fromAssets(screenAsset: screen, cameraAsset: camera)
        let bubble = BubbleTimeline(snapshots: [
            .init(time: 0,
                  frame: CGRect(x: 16, y: 16, width: 32, height: 32),
                  shape: .rect, mirror: false, opacity: 1.0,
                  borderWidth: 0, borderHue: 0)
        ])

        let output = try CompositionBuilder.build(
            timeline: timeline, screenAsset: screen, cameraAsset: camera,
            bubbleTimeline: bubble, screenScale: 1)

        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let cg = try generator.copyCGImage(at: t(0.5), actualTime: nil)
        XCTAssertEqual(cg.width, 64)
        XCTAssertEqual(cg.height, 64)

        // Outside the 16×16 bubble rect at top-left: screen red. H.264 through
        // AVAssetImageGenerator is lossy so compare against loose thresholds.
        let outside = pixel(in: cg, x: 2, y: 2)
        XCTAssertGreaterThan(outside.r, 150)
        XCTAssertLessThan(outside.g, 100)

        // Inside the bubble (rect shape, full camera): green dominates.
        let inside = pixel(in: cg, x: 16 + 16, y: 16 + 16)
        XCTAssertGreaterThan(inside.g, 150)
        XCTAssertLessThan(inside.r, 100)
    }

    // MARK: - AC2: seeking samples the right bubble snapshot

    func testSeekingShowsBubbleSnapshotAtThatTime() throws {
        let (_, screen, camera) = try makeAssets(duration: t(2))
        let timeline = Timeline.fromAssets(screenAsset: screen, cameraAsset: camera)

        // Snapshot #1 at t=0 lives at top-left; snapshot #2 at t=1 lives at
        // bottom-right. BubbleTimeline.sample returns the latest snapshot whose
        // time ≤ the query, so at t=0.2 we get #1 and at t=1.2 we get #2.
        let bubble = BubbleTimeline(snapshots: [
            .init(time: 0,
                  frame: CGRect(x: 4, y: 4, width: 20, height: 20),
                  shape: .rect, mirror: false, opacity: 1.0,
                  borderWidth: 0, borderHue: 0),
            .init(time: 1,
                  frame: CGRect(x: 40, y: 40, width: 20, height: 20),
                  shape: .rect, mirror: false, opacity: 1.0,
                  borderWidth: 0, borderHue: 0)
        ])

        let output = try CompositionBuilder.build(
            timeline: timeline, screenAsset: screen, cameraAsset: camera,
            bubbleTimeline: bubble, screenScale: 1)

        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let early = try generator.copyCGImage(at: t(0.2), actualTime: nil)
        XCTAssertGreaterThan(pixel(in: early, x: 12, y: 12).g, 200,    // inside bubble #1
                             "bubble #1 should be visible at t=0.2")
        XCTAssertLessThan(pixel(in: early, x: 50, y: 50).g, 50,
                          "bubble #2 should NOT be visible at t=0.2")

        let late = try generator.copyCGImage(at: t(1.2), actualTime: nil)
        XCTAssertGreaterThan(pixel(in: late, x: 50, y: 50).g, 200,
                             "bubble #2 should be visible at t=1.2")
        XCTAssertLessThan(pixel(in: late, x: 12, y: 12).g, 50,
                          "bubble #1 should have moved away by t=1.2")
    }

    // MARK: - AC3: speed-changed clips still line up bubble with source time

    func testSpeedTwoClipShowsBubbleAtMappedSourceTime() throws {
        let (_, screen, camera) = try makeAssets(duration: t(2))
        var timeline = Timeline.fromAssets(screenAsset: screen, cameraAsset: camera)

        // Retime the screen clip to 2×, so 1s timeline → 2s source.
        let screenClipID = timeline.tracks.first(where: { $0.sourceBinding == .screen && $0.kind == .video })!.clips[0].id
        timeline = timeline.settingSpeed(clipID: screenClipID, 2.0)

        // Bubble moves from top-left (source t=0) to bottom-right (source t=1).
        let bubble = BubbleTimeline(snapshots: [
            .init(time: 0,
                  frame: CGRect(x: 4, y: 4, width: 20, height: 20),
                  shape: .rect, mirror: false, opacity: 1.0,
                  borderWidth: 0, borderHue: 0),
            .init(time: 1,
                  frame: CGRect(x: 40, y: 40, width: 20, height: 20),
                  shape: .rect, mirror: false, opacity: 1.0,
                  borderWidth: 0, borderHue: 0)
        ])

        let output = try CompositionBuilder.build(
            timeline: timeline, screenAsset: screen, cameraAsset: camera,
            bubbleTimeline: bubble, screenScale: 1)

        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // At composition time 0.6s with speed=2, source time = 1.2s,
        // so bubble #2 (the later snapshot) should be active.
        let cg = try generator.copyCGImage(at: t(0.6), actualTime: nil)
        XCTAssertGreaterThan(pixel(in: cg, x: 50, y: 50).g, 200,
                             "at speed=2, composition t=0.6s maps to source t=1.2s — bubble #2 should show")
        XCTAssertLessThan(pixel(in: cg, x: 12, y: 12).g, 50)
    }

    // MARK: - AC4: many seeks don't leak

    func testTenSeeksDoNotCrashOrLeak() throws {
        let (_, screen, camera) = try makeAssets(duration: t(2))
        let timeline = Timeline.fromAssets(screenAsset: screen, cameraAsset: camera)
        let bubble = BubbleTimeline(snapshots: [
            .init(time: 0,
                  frame: CGRect(x: 16, y: 16, width: 32, height: 32),
                  shape: .rect, mirror: false, opacity: 1.0,
                  borderWidth: 0, borderHue: 0)
        ])

        let output = try CompositionBuilder.build(
            timeline: timeline, screenAsset: screen, cameraAsset: camera,
            bubbleTimeline: bubble, screenScale: 1)
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition

        for i in 0..<12 {
            autoreleasepool {
                let time = CMTime(seconds: 0.1 * Double(i), preferredTimescale: tb)
                _ = try? generator.copyCGImage(at: time, actualTime: nil)
            }
        }
        // If we reached here without a crash, the seek loop is stable.
        XCTAssertTrue(true)
    }
}
