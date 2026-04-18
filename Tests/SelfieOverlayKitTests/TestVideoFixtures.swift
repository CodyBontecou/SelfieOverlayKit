import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Writes a short synthetic MOV to disk for tests that need a real AVAsset
/// with a known duration. Produces a single black frame, stretched to the
/// requested duration at 30 fps, at a minimal resolution (64×64) so writes
/// stay fast in CI.
enum TestVideoFixtures {

    static func writeBlackMOV(
        to url: URL,
        duration: CMTime,
        size: CGSize = CGSize(width: 64, height: 64)
    ) throws {
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let pixelBuffer = makeBlackPixelBuffer(size: size)
        let fps: Int32 = 30
        let frameCount = max(1, Int(duration.seconds * Double(fps)))
        let frameDuration = CMTime(value: 1, timescale: fps)

        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(i))
            adaptor.append(pixelBuffer, withPresentationTime: pts)
        }
        input.markAsFinished()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()

        if let error = writer.error {
            throw error
        }
    }

    private static func makeBlackPixelBuffer(size: CGSize) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs,
            &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0, bytesPerRow * Int(size.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
