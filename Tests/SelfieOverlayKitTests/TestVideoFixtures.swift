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
        size: CGSize = CGSize(width: 64, height: 64),
        withSilentAudio: Bool = false
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

        var audioInput: AVAssetWriterInput?
        if withSilentAudio {
            // LPCM (not AAC) so AVFoundation can scale / slice the track on the
            // simulator without re-entering the AAC decoder, which has been
            // observed to hang scaleTimeRange calls during tests.
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            audioInput = a
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let pixelBuffer = makeBlackPixelBuffer(size: size)
        let fps: Int32 = 30
        let frameCount = max(1, Int(duration.seconds * Double(fps)))
        let frameDuration = CMTime(value: 1, timescale: fps)

        // Drive video + audio concurrently on separate queues so the writer
        // can interleave. Serial writes stalled for multi-second durations
        // because the audio input would block waiting for the video encoder
        // to drain even after markAsFinished.
        let videoQueue = DispatchQueue(label: "fixture.video")
        let audioQueue = DispatchQueue(label: "fixture.audio")
        let group = DispatchGroup()

        group.enter()
        var videoIndex = 0
        input.requestMediaDataWhenReady(on: videoQueue) {
            while input.isReadyForMoreMediaData {
                if videoIndex >= frameCount {
                    input.markAsFinished()
                    group.leave()
                    return
                }
                let pts = CMTimeMultiply(frameDuration, multiplier: Int32(videoIndex))
                adaptor.append(pixelBuffer, withPresentationTime: pts)
                videoIndex += 1
            }
        }

        if let audioInput {
            group.enter()
            audioQueue.async {
                do {
                    try appendSilentAudio(to: audioInput, duration: duration)
                } catch {
                    // Writer error will surface through writer.error below.
                }
                audioInput.markAsFinished()
                group.leave()
            }
        }

        group.wait()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()

        if let error = writer.error {
            throw error
        }
    }

    private static func appendSilentAudio(to input: AVAssetWriterInput,
                                          duration: CMTime) throws {
        let sampleRate: Double = 44100
        // Large chunks — small chunks interacted poorly with the writer's
        // interleave backpressure and stalled isReadyForMoreMediaData on
        // multi-second durations.
        let chunkSamples = 22050
        var description: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0)
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description)
        guard let description else { return }

        let totalFrames = Int(duration.seconds * sampleRate)
        var written = 0
        while written < totalFrames {
            // Bounded wait: isReadyForMoreMediaData flips as the writer drains.
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let framesThisChunk = min(chunkSamples, totalFrames - written)
            let byteCount = framesThisChunk * 2  // 16-bit mono

            var blockBuffer: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer)
            CMBlockBufferFillDataBytes(
                with: 0,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: byteCount)

            var sampleBuffer: CMSampleBuffer?
            let pts = CMTime(value: CMTimeValue(written), timescale: CMTimeScale(sampleRate))
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid)
            var sampleSize = 2
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: description,
                sampleCount: framesThisChunk,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer)
            if let sampleBuffer {
                input.append(sampleBuffer)
            }
            written += framesThisChunk
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
