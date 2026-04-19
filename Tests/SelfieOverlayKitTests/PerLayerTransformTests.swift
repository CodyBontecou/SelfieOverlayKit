import CoreGraphics
import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class PerLayerTransformTests: XCTestCase {

    private let tb: CMTimeScale = 600

    private func t(_ s: Double) -> CMTime {
        CMTime(seconds: s, preferredTimescale: tb)
    }

    private func range(_ s: Double, duration d: Double) -> CMTimeRange {
        CMTimeRange(start: t(s), duration: t(d))
    }

    private func makeTimeline() -> Timeline {
        let screen = Clip(
            sourceID: .screen,
            sourceRange: range(0, duration: 10),
            timelineRange: range(0, duration: 10))
        let camera = Clip(
            sourceID: .camera,
            sourceRange: range(0, duration: 10),
            timelineRange: range(0, duration: 10))
        return Timeline(
            tracks: [
                Track(kind: .video, sourceBinding: .screen, clips: [screen]),
                Track(kind: .video, sourceBinding: .camera, clips: [camera])
            ],
            duration: t(10))
    }

    // MARK: - Defaults

    func testClipDefaultsAreIdentity() {
        let clip = Clip(
            sourceID: .screen,
            sourceRange: range(0, duration: 1),
            timelineRange: range(0, duration: 1))
        XCTAssertEqual(clip.canvasScale, 1.0)
        XCTAssertEqual(clip.canvasOffset, .zero)
        XCTAssertEqual(clip.cropRect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertNil(clip.cameraShape)
    }

    // MARK: - Mutations

    func testSettingCanvasScaleClampsAndIsPure() {
        let tl = makeTimeline()
        let clipID = tl.tracks[0].clips[0].id

        let out = tl.settingCanvasScale(clipID: clipID, 2.5)
        XCTAssertEqual(out.tracks[0].clips[0].canvasScale, 2.5)
        XCTAssertEqual(tl.tracks[0].clips[0].canvasScale, 1.0, "original must not mutate")

        let clampedLow = tl.settingCanvasScale(clipID: clipID, -0.5)
        XCTAssertEqual(clampedLow.tracks[0].clips[0].canvasScale, Timeline.canvasScaleRange.lowerBound)

        let clampedHigh = tl.settingCanvasScale(clipID: clipID, 100)
        XCTAssertEqual(clampedHigh.tracks[0].clips[0].canvasScale, Timeline.canvasScaleRange.upperBound)
    }

    func testSettingCanvasOffsetStoresRawPoint() {
        let tl = makeTimeline()
        let clipID = tl.tracks[1].clips[0].id
        let out = tl.settingCanvasOffset(clipID: clipID, CGPoint(x: -120, y: 48))
        XCTAssertEqual(out.tracks[1].clips[0].canvasOffset, CGPoint(x: -120, y: 48))
    }

    func testSettingCropRectClampsToUnitSquare() {
        let tl = makeTimeline()
        let clipID = tl.tracks[0].clips[0].id

        let out = tl.settingCropRect(clipID: clipID,
                                     CGRect(x: -0.2, y: 0.3, width: 2.0, height: 0.4))
        let r = out.tracks[0].clips[0].cropRect
        XCTAssertEqual(r.minX, 0)
        XCTAssertEqual(r.minY, 0.3, accuracy: 1e-6)
        XCTAssertEqual(r.maxX, 1)
        XCTAssertEqual(r.maxY, 0.7, accuracy: 1e-6)
    }

    func testSettingCropRectGuardsAgainstZeroArea() {
        let tl = makeTimeline()
        let clipID = tl.tracks[0].clips[0].id

        let out = tl.settingCropRect(clipID: clipID,
                                     CGRect(x: 0.5, y: 0.5, width: 0, height: 0))
        let r = out.tracks[0].clips[0].cropRect
        XCTAssertGreaterThan(r.width, 0)
        XCTAssertGreaterThan(r.height, 0)
    }

    func testSettingCameraShapeRoundTrips() {
        let tl = makeTimeline()
        let clipID = tl.tracks[1].clips[0].id

        let out = tl.settingCameraShape(clipID: clipID, .fullscreen)
        XCTAssertEqual(out.tracks[1].clips[0].cameraShape, .fullscreen)

        let cleared = out.settingCameraShape(clipID: clipID, nil)
        XCTAssertNil(cleared.tracks[1].clips[0].cameraShape)
    }

    // MARK: - Split / duplicate preserve transforms

    func testSplitPreservesTransformOnBothHalves() {
        var tl = makeTimeline()
        let clipID = tl.tracks[1].clips[0].id
        tl = tl.settingCanvasScale(clipID: clipID, 1.5)
        tl = tl.settingCanvasOffset(clipID: clipID, CGPoint(x: 30, y: -10))
        tl = tl.settingCropRect(clipID: clipID, CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        tl = tl.settingCameraShape(clipID: clipID, .rect)

        let out = tl.splitting(at: t(4), trackID: tl.tracks[1].id)
        XCTAssertEqual(out.tracks[1].clips.count, 2)
        for half in out.tracks[1].clips {
            XCTAssertEqual(half.canvasScale, 1.5)
            XCTAssertEqual(half.canvasOffset, CGPoint(x: 30, y: -10))
            XCTAssertEqual(half.cropRect, CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
            XCTAssertEqual(half.cameraShape, .rect)
        }
    }

    func testDuplicatePreservesTransform() {
        var tl = makeTimeline()
        let clipID = tl.tracks[1].clips[0].id
        tl = tl.settingCanvasScale(clipID: clipID, 0.75)
        tl = tl.settingCameraShape(clipID: clipID, .circle)

        let out = tl.duplicating(clipID: clipID)
        XCTAssertEqual(out.tracks[1].clips.count, 2)
        let duplicate = out.tracks[1].clips[1]
        XCTAssertEqual(duplicate.canvasScale, 0.75)
        XCTAssertEqual(duplicate.cameraShape, .circle)
        XCTAssertNotEqual(duplicate.id, clipID, "duplicate must have a fresh id")
    }

    // MARK: - Codable

    func testCodableRoundTripPreservesTransforms() throws {
        var tl = makeTimeline()
        let screenID = tl.tracks[0].clips[0].id
        let cameraID = tl.tracks[1].clips[0].id
        tl = tl.settingCanvasScale(clipID: screenID, 0.5)
        tl = tl.settingCanvasOffset(clipID: screenID, CGPoint(x: -50, y: 25))
        tl = tl.settingCropRect(clipID: screenID, CGRect(x: 0.2, y: 0, width: 0.6, height: 1))
        tl = tl.settingCameraShape(clipID: cameraID, .fullscreen)

        let data = try JSONEncoder().encode(tl)
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)

        XCTAssertEqual(decoded.tracks[0].clips[0].canvasScale, 0.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.tracks[0].clips[0].canvasOffset.x, -50, accuracy: 1e-9)
        XCTAssertEqual(decoded.tracks[0].clips[0].canvasOffset.y, 25, accuracy: 1e-9)
        let r = decoded.tracks[0].clips[0].cropRect
        XCTAssertEqual(r.origin.x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(r.origin.y, 0, accuracy: 1e-9)
        XCTAssertEqual(r.width, 0.6, accuracy: 1e-9)
        XCTAssertEqual(r.height, 1, accuracy: 1e-9)
        XCTAssertEqual(decoded.tracks[1].clips[0].cameraShape, .fullscreen)
    }

    func testDecodesLegacyJSONWithoutTransformFields() throws {
        // Simulates a pre-feature project file — the new keys are absent and
        // must default to identity so older projects keep loading.
        let json = """
        {
          "tracks": [
            {
              "id": "\(UUID().uuidString)",
              "kind": "video",
              "sourceBinding": "screen",
              "clips": [
                {
                  "id": "\(UUID().uuidString)",
                  "sourceID": "screen",
                  "sourceRange": { "start": { "value": 0, "timescale": 600 },
                                   "duration": { "value": 6000, "timescale": 600 } },
                  "timelineRange": { "start": { "value": 0, "timescale": 600 },
                                     "duration": { "value": 6000, "timescale": 600 } },
                  "speed": 1.0,
                  "volume": 1.0
                }
              ]
            }
          ],
          "duration": { "value": 6000, "timescale": 600 }
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)
        let clip = decoded.tracks[0].clips[0]
        XCTAssertEqual(clip.canvasScale, 1.0)
        XCTAssertEqual(clip.canvasOffset, .zero)
        XCTAssertEqual(clip.cropRect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertNil(clip.cameraShape)
    }

    func testIdentityTransformsOmittedFromEncodedJSON() throws {
        let tl = makeTimeline()
        let data = try JSONEncoder().encode(tl)
        let json = String(data: data, encoding: .utf8) ?? ""
        // Identity transforms should stay absent from the on-disk payload so
        // legacy project files round-trip byte-for-byte clean.
        XCTAssertFalse(json.contains("canvasScale"))
        XCTAssertFalse(json.contains("canvasOffset"))
        XCTAssertFalse(json.contains("cropRect"))
        XCTAssertFalse(json.contains("cameraShape"))
    }
}
