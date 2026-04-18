import UIKit
import AVFoundation
import CoreImage

/// A UIView that displays front-camera sample buffers by assigning CGImages to
/// `layer.contents`. Subscribes to the shared `CameraSession` listener fanout so
/// the recording pipeline can consume the same frames independently.
final class CameraPreviewView: UIView {

    private let ciContext: CIContext = {
        let device = MTLCreateSystemDefaultDevice()
        return device.map { CIContext(mtlDevice: $0) } ?? CIContext()
    }()

    weak var cameraSession: CameraSession? {
        didSet {
            oldValue?.removeSampleBufferListener(self)
            cameraSession?.addSampleBufferListener(self) { [weak self] sample in
                self?.handle(sample)
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        cameraSession?.removeSampleBufferListener(self)
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let source = CIImage(cvPixelBuffer: pixelBuffer)

        // Keep the CGImage small — the bubble caps at ~320pt, so a 512px longest side
        // covers @2x and @3x without burning memory on a full 1280×720 frame every tick.
        let targetLongSide: CGFloat = 512
        let longSide = max(source.extent.width, source.extent.height)
        let scale = longSide > targetLongSide ? targetLongSide / longSide : 1.0
        let scaled = scale < 1.0
            ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : source

        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.layer.contents = cgImage
        }
    }
}
