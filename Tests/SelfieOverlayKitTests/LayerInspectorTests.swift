import CoreMedia
import XCTest
@testable import SelfieOverlayKit

final class LayerInspectorTests: XCTestCase {

    private let tb: CMTimeScale = 600

    private func range(_ s: Double, duration d: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: s, preferredTimescale: tb),
                    duration: CMTime(seconds: d, preferredTimescale: tb))
    }

    // MARK: - Scale slider math

    func testScaleSliderMathRoundtrips() {
        for scale in [0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0] {
            let slider = ClipInspectorView.sliderFromScale(CGFloat(scale))
            let back = ClipInspectorView.scaleFromSlider(slider)
            XCTAssertEqual(back, scale, accuracy: 0.01, "roundtrip for \(scale)")
        }
    }

    func testScaleBoundsCoverRequestedRange() {
        XCTAssertEqual(ClipInspectorView.scaleFromSlider(-2), 0.25, accuracy: 1e-6)
        XCTAssertEqual(ClipInspectorView.scaleFromSlider(2), 4.0, accuracy: 1e-6)
    }

    // MARK: - configure visibility

    func testConfigureHidesScaleRowForAudioClip() {
        let inspector = ClipInspectorView(frame: .zero)
        let audioClip = Clip(
            sourceID: .mic,
            sourceRange: range(0, duration: 5),
            timelineRange: range(0, duration: 5))
        inspector.configure(with: audioClip, trackKind: .audio)
        XCTAssertTrue(inspector.scaleRow.isHidden)
        XCTAssertTrue(inspector.cameraShapeRow.isHidden)
        XCTAssertFalse(inspector.volumeRow.isHidden)
    }

    func testConfigureShowsScaleOnlyForScreenClip() {
        let inspector = ClipInspectorView(frame: .zero)
        let screenClip = Clip(
            sourceID: .screen,
            sourceRange: range(0, duration: 5),
            timelineRange: range(0, duration: 5))
        inspector.configure(with: screenClip, trackKind: .video)
        XCTAssertFalse(inspector.scaleRow.isHidden)
        XCTAssertTrue(inspector.cameraShapeRow.isHidden, "only camera clips get the shape picker")
    }

    func testConfigureShowsScaleAndShapeForCameraClip() {
        let inspector = ClipInspectorView(frame: .zero)
        let cameraClip = Clip(
            sourceID: .camera,
            sourceRange: range(0, duration: 5),
            timelineRange: range(0, duration: 5),
            cameraShape: .fullscreen)
        inspector.configure(with: cameraClip, trackKind: .video)
        XCTAssertFalse(inspector.scaleRow.isHidden)
        XCTAssertFalse(inspector.cameraShapeRow.isHidden)
        XCTAssertEqual(
            inspector.cameraShapeControl.selectedSegmentIndex,
            ClipInspectorView.cameraShapeOptions.firstIndex(of: .fullscreen))
    }

    func testConfigurePrimesScaleSliderToClipValue() {
        let inspector = ClipInspectorView(frame: .zero)
        let clip = Clip(
            sourceID: .screen,
            sourceRange: range(0, duration: 5),
            timelineRange: range(0, duration: 5),
            canvasScale: 2.0)
        inspector.configure(with: clip, trackKind: .video)
        XCTAssertEqual(inspector.scaleSlider.value,
                       ClipInspectorView.sliderFromScale(2.0),
                       accuracy: 1e-6)
    }
}
