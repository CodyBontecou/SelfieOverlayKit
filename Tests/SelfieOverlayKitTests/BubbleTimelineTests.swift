import XCTest
@testable import SelfieOverlayKit

final class BubbleTimelineTests: XCTestCase {

    private func snap(_ t: TimeInterval, x: CGFloat) -> BubbleTimeline.Snapshot {
        BubbleTimeline.Snapshot(
            time: t,
            frame: CGRect(x: x, y: 0, width: 140, height: 140),
            shape: .circle,
            mirror: true,
            opacity: 1.0,
            borderWidth: 2,
            borderHue: 0.58)
    }

    func testEmptyTimelineReturnsNil() {
        let tl = BubbleTimeline(snapshots: [])
        XCTAssertNil(tl.sample(at: 0))
        XCTAssertNil(tl.sample(at: 5))
    }

    func testBeforeFirstClampsToFirst() {
        let tl = BubbleTimeline(snapshots: [snap(1.0, x: 100)])
        let s = try! XCTUnwrap(tl.sample(at: 0))
        XCTAssertEqual(s.frame.origin.x, 100, accuracy: 1e-6)
    }

    func testReturnsMostRecentAtOrBeforeT() throws {
        let tl = BubbleTimeline(snapshots: [
            snap(0.0, x: 0),
            snap(1.0, x: 100),
            snap(2.0, x: 200)
        ])
        XCTAssertEqual(try XCTUnwrap(tl.sample(at: 0.5)).frame.origin.x, 0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(tl.sample(at: 1.0)).frame.origin.x, 100, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(tl.sample(at: 1.5)).frame.origin.x, 100, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(tl.sample(at: 2.5)).frame.origin.x, 200, accuracy: 1e-6)
    }
}
