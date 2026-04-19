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

    // MARK: - Per-layer transform tests

    func testScreenScaledDownExposesBackgroundColor() {
        let size = CGSize(width: 128, height: 128)
        let screen = solidBuffer(size: size, color: (255, 0, 0, 255))   // red
        let dest = solidBuffer(size: size, color: (0, 0, 0, 255))

        let shrink = BubbleOverlayRenderer.LayerTransform(
            cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            scale: 0.5,
            offset: .zero)
        // Bright blue background so the uncovered pixels are obvious.
        let bg = CIColor(red: 0, green: 0, blue: 1)

        renderer.render(
            screen: screen,
            camera: nil,
            state: nil,
            screenScale: 1,
            outputSize: size,
            screenTransform: shrink,
            backgroundColor: bg,
            into: dest,
            context: context)

        // Near-canvas corner should show the background.
        let corner = pixel(of: dest, x: 4, y: 4)
        XCTAssertLessThan(corner.r, 30, "background must replace red in corner")
        XCTAssertGreaterThan(corner.b, 200)

        // Canvas centre should still show the red screen.
        let centre = pixel(of: dest, x: 64, y: 64)
        XCTAssertGreaterThan(centre.r, 200)
        XCTAssertLessThan(centre.b, 30)
    }

    func testFullscreenCameraOverrideCoversEntireCanvas() {
        let size = CGSize(width: 128, height: 128)
        let screen = solidBuffer(size: size, color: (255, 0, 0, 255))
        let camera = solidBuffer(size: size, color: (0, 255, 0, 255))
        let dest = solidBuffer(size: size, color: (0, 0, 0, 255))

        // A tiny bubble rect — without the override, camera should only
        // cover a small square.
        let state = BubbleOverlayRenderer.State(
            frame: CGRect(x: 0, y: 0, width: 16, height: 16),
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
            cameraShapeOverride: .fullscreen,
            into: dest,
            context: context)

        for point in [(4, 4), (64, 64), (120, 120)] {
            let px = pixel(of: dest, x: point.0, y: point.1)
            XCTAssertLessThan(px.r, 10, "fullscreen camera must replace screen at (\(point.0),\(point.1))")
            XCTAssertGreaterThan(px.g, 240)
        }
    }

    func testIdentityTransformPreservesExistingRendering() {
        // Guard rail: identity LayerTransform must produce byte-identical
        // output to the pre-feature code path, so projects without any
        // per-layer edits render unchanged.
        let size = CGSize(width: 128, height: 128)
        let screen = solidBuffer(size: size, color: (120, 80, 200, 255))
        let camera = solidBuffer(size: size, color: (30, 200, 30, 255))

        let state = BubbleOverlayRenderer.State(
            frame: CGRect(x: 32, y: 32, width: 64, height: 64),
            shape: .circle,
            mirror: false,
            opacity: 1.0,
            borderWidth: 0,
            borderHue: 0)

        let destA = solidBuffer(size: size, color: (0, 0, 0, 255))
        renderer.render(screen: screen, camera: camera, state: state,
                        screenScale: 1, outputSize: size,
                        into: destA, context: context)

        let destB = solidBuffer(size: size, color: (0, 0, 0, 255))
        renderer.render(screen: screen, camera: camera, state: state,
                        screenScale: 1, outputSize: size,
                        screenTransform: .identity,
                        cameraTransform: .identity,
                        cameraShapeOverride: nil,
                        backgroundColor: CIColor(red: 1, green: 0, blue: 1),
                        into: destB, context: context)

        for (x, y) in [(5, 5), (32, 32), (64, 64), (100, 100)] {
            let a = pixel(of: destA, x: x, y: y)
            let b = pixel(of: destB, x: x, y: y)
            XCTAssertEqual(a.r, b.r, accuracy: 1, "identity path must match default path at (\(x),\(y))")
            XCTAssertEqual(a.g, b.g, accuracy: 1)
            XCTAssertEqual(a.b, b.b, accuracy: 1)
        }
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
