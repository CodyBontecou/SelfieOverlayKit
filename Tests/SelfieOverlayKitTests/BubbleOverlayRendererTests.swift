import CoreImage
import CoreVideo
import Foundation
import UIKit
import XCTest
@testable import SelfieOverlayKit

final class BubbleOverlayRendererTests: XCTestCase {

    private let context = CIContext(options: [.workingColorSpace: NSNull()])
    private let renderer = BubbleOverlayRenderer()

    // MARK: - Pixel helpers

    /// BGRA pixel buffer filled with a solid color.
    private func solidBuffer(size: CGSize, color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> CVPixelBuffer {
        let w = Int(size.width)
        let h = Int(size.height)
        var pb: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let p = base + y * bytesPerRow + x * 4
                // BGRA
                p[0] = color.b
                p[1] = color.g
                p[2] = color.r
                p[3] = color.a
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func pixel(of buffer: CVPixelBuffer, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let p = base + y * bytesPerRow + x * 4
        return (p[2], p[1], p[0], p[3])
    }

    // MARK: - Tests

    func testNilStateCopiesScreenThrough() {
        let size = CGSize(width: 64, height: 64)
        let screen = solidBuffer(size: size, color: (200, 50, 10, 255))
        let dest = solidBuffer(size: size, color: (0, 0, 0, 255))

        renderer.render(
            screen: screen,
            camera: nil,
            state: nil,
            screenScale: 1,
            outputSize: size,
            into: dest,
            context: context)

        let px = pixel(of: dest, x: 10, y: 10)
        XCTAssertEqual(px.r, 200, accuracy: 2)
        XCTAssertEqual(px.g, 50, accuracy: 2)
        XCTAssertEqual(px.b, 10, accuracy: 2)
    }

    func testRectBubbleReplacesScreenPixelsInsideItsFrame() {
        let size = CGSize(width: 128, height: 128)
        let screen = solidBuffer(size: size, color: (255, 0, 0, 255))   // red everywhere
        let camera = solidBuffer(size: size, color: (0, 255, 0, 255))   // green camera
        let dest = solidBuffer(size: size, color: (0, 0, 0, 255))

        // Bubble at 16x16 → 48x48 in points at scale 1 (48×48 pixels).
        let state = BubbleOverlayRenderer.State(
            frame: CGRect(x: 16, y: 16, width: 48, height: 48),
            shape: .rect,
            mirror: false,
            opacity: 1.0,
            borderWidth: 0,
            borderHue: 0)

        renderer.render(
            screen: screen,
            camera: camera,
            state: state,
            screenScale: 1,
            outputSize: size,
            into: dest,
            context: context)

        // state.frame is top-origin (points). The renderer flips y internally
        // when translating the bubble into CIImage's bottom-origin space, so
        // the bubble lands at the same (x, y, w, h) rectangle in the output
        // CVPixelBuffer's top-origin coordinates.
        let inside = pixel(of: dest, x: 16 + 24, y: 16 + 24)
        XCTAssertEqual(inside.r, 0, accuracy: 5)
        XCTAssertEqual(inside.g, 255, accuracy: 5)
        XCTAssertEqual(inside.b, 0, accuracy: 5)

        // Well outside the bubble: expect red (screen).
        let outside = pixel(of: dest, x: 2, y: 2)
        XCTAssertEqual(outside.r, 255, accuracy: 5)
        XCTAssertEqual(outside.g, 0, accuracy: 5)
        XCTAssertEqual(outside.b, 0, accuracy: 5)
    }

    func testCircleShapeMasksCornersAway() {
        let size = CGSize(width: 128, height: 128)
        let screen = solidBuffer(size: size, color: (255, 0, 0, 255))
        let camera = solidBuffer(size: size, color: (0, 255, 0, 255))
        let dest = solidBuffer(size: size, color: (0, 0, 0, 255))

        let state = BubbleOverlayRenderer.State(
            frame: CGRect(x: 32, y: 32, width: 64, height: 64),
            shape: .circle,
            mirror: false,
            opacity: 1.0,
            borderWidth: 0,
            borderHue: 0)

        renderer.render(
            screen: screen,
            camera: camera,
            state: state,
            screenScale: 1,
            outputSize: size,
            into: dest,
            context: context)

        // Corner of the bubble rect: circle mask excludes it, so screen
        // (red) shows through. state.frame is top-origin like the buffer.
        let corner = pixel(of: dest, x: 32 + 1, y: 32 + 1)
        XCTAssertEqual(corner.r, 255, accuracy: 5, "circle mask must clip corner pixel back to screen")
        XCTAssertLessThan(corner.g, 50)

        // Center of the circle: camera (green) dominates.
        let center = pixel(of: dest, x: 32 + 32, y: 32 + 32)
        XCTAssertGreaterThan(center.g, 200)
    }
}
