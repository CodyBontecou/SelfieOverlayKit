import AVFoundation
import CoreMedia
import UIKit
import XCTest
@testable import SelfieOverlayKit

final class ThumbnailAndWaveformTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ProjectStore!
    private let tb: CMTimeScale = 600

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ThumbnailAndWaveformTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Thumbnail strip

    func testRenderStripProducesExpectedImageSize() throws {
        let project = try store.create()
        try TestVideoFixtures.writeBlackMOV(to: project.screenURL, duration: t(2),
                                            color: (200, 50, 50))
        let asset = AVURLAsset(url: project.screenURL)
        let thumbSize = CGSize(width: 44, height: 44)
        let strip = ThumbnailStripRenderer.renderStrip(asset: asset, count: 4,
                                                       thumbnailSize: thumbSize)
        XCTAssertNotNil(strip)
        XCTAssertEqual(strip?.size.width ?? 0, thumbSize.width * 4, accuracy: 1.0)
        XCTAssertEqual(strip?.size.height ?? 0, thumbSize.height, accuracy: 1.0)
    }

    func testRenderAndCacheRoundtripsViaDisk() throws {
        let project = try store.create()
        try TestVideoFixtures.writeBlackMOV(to: project.screenURL, duration: t(1),
                                            color: (50, 150, 50))
        let asset = AVURLAsset(url: project.screenURL)
        let cacheURL = project.folderURL.appendingPathComponent("cache/thumbs_screen.png")

        let done = expectation(description: "render + cache completes")
        ThumbnailStripRenderer.shared.renderAndCache(
            asset: asset, cacheURL: cacheURL,
            count: 3, thumbnailSize: CGSize(width: 32, height: 32)
        ) { image in
            XCTAssertNotNil(image)
            done.fulfill()
        }
        wait(for: [done], timeout: 10.0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertNotNil(ThumbnailStripRenderer.shared.cachedStrip(at: cacheURL))
    }

    // MARK: - Waveform

    func testWaveformPeaksHaveExpectedDensity() throws {
        let project = try store.create()
        try TestVideoFixtures.writeBlackMOV(to: project.screenURL, duration: t(1),
                                            color: (0, 0, 0), withSilentAudio: true)
        let asset = AVURLAsset(url: project.screenURL)
        let peaks = try WaveformRenderer.renderPeaks(asset: asset, peaksPerSecond: 20)
        // ~20 peaks/s over a 1s clip → ~20 peaks.
        XCTAssertGreaterThan(peaks.count, 15)
        XCTAssertLessThan(peaks.count, 25)
        // Silent audio → all peaks are zero.
        for peak in peaks {
            XCTAssertEqual(peak, 0, accuracy: 0.01)
        }
    }

    func testWaveformCacheRoundtripsIntegers() throws {
        let project = try store.create()
        try TestVideoFixtures.writeBlackMOV(to: project.screenURL, duration: t(1),
                                            color: (0, 0, 0), withSilentAudio: true)
        let asset = AVURLAsset(url: project.screenURL)
        let cacheURL = project.folderURL.appendingPathComponent("cache/waveform_mic.bin")

        let done = expectation(description: "waveform render + cache completes")
        WaveformRenderer.shared.renderAndCache(
            asset: asset, cacheURL: cacheURL, peaksPerSecond: 20
        ) { peaks in
            XCTAssertNotNil(peaks)
            done.fulfill()
        }
        wait(for: [done], timeout: 10.0)

        let cached = WaveformRenderer.shared.cachedPeaks(at: cacheURL)
        XCTAssertNotNil(cached)
        XCTAssertFalse(cached?.isEmpty ?? true)
    }

    // MARK: - Trim reveals / hides cached data without regen

    func testWaveformViewPeakRangeControlsDrawnWindow() {
        let view = WaveformView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        view.peaks = Array(repeating: Float(0.5), count: 100)
        view.peakRange = 0..<100
        XCTAssertEqual(view.peakRange?.count, 100)

        // Simulate a trim: narrow the range to the middle half.
        view.peakRange = 25..<75
        XCTAssertEqual(view.peakRange?.count, 50)
    }
}
