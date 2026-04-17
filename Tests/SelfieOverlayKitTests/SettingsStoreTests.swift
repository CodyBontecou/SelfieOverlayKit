import XCTest
@testable import SelfieOverlayKit

final class SettingsStoreTests: XCTestCase {

    private func makeStore() -> (SettingsStore, UserDefaults, String) {
        let suite = "SelfieOverlayKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: defaults), defaults, suite)
    }

    func testDefaults() {
        let (store, _, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertEqual(store.shape, .circle)
        XCTAssertTrue(store.mirror)
        XCTAssertEqual(store.opacity, 1.0)
        XCTAssertEqual(store.size, 140)
    }

    func testPersistenceRoundTrip() {
        let suite = "SelfieOverlayKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let writer = SettingsStore(defaults: defaults)
        writer.shape = .roundedRect
        writer.mirror = false
        writer.opacity = 0.5
        writer.size = 220
        writer.position = CGPoint(x: 40, y: 60)
        writer.borderWidth = 4
        writer.borderHue = 0.1

        let reader = SettingsStore(defaults: defaults)
        XCTAssertEqual(reader.shape, .roundedRect)
        XCTAssertFalse(reader.mirror)
        XCTAssertEqual(reader.opacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(reader.size, 220)
        XCTAssertEqual(reader.position, CGPoint(x: 40, y: 60))
        XCTAssertEqual(reader.borderWidth, 4)
        XCTAssertEqual(reader.borderHue, 0.1, accuracy: 0.0001)
    }

    func testResetRestoresDefaults() {
        let (store, _, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.shape = .rect
        store.mirror = false
        store.opacity = 0.3
        store.reset()
        XCTAssertEqual(store.shape, .circle)
        XCTAssertTrue(store.mirror)
        XCTAssertEqual(store.opacity, 1.0)
    }
}
