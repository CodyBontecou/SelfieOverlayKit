import Foundation
import Combine
import UIKit

public enum BubbleShape: String, CaseIterable, Codable {
    case circle
    case roundedRect
    case rect

    public var displayName: String {
        switch self {
        case .circle: return "Circle"
        case .roundedRect: return "Rounded"
        case .rect: return "Square"
        }
    }
}

/// Observable settings that persist to UserDefaults. Host apps can read/write these
/// directly, or hand users the built-in settings sheet.
public final class SettingsStore: ObservableObject {

    private enum Key {
        static let shape = "SelfieOverlay.shape"
        static let mirror = "SelfieOverlay.mirror"
        static let opacity = "SelfieOverlay.opacity"
        static let size = "SelfieOverlay.size"
        static let positionX = "SelfieOverlay.positionX"
        static let positionY = "SelfieOverlay.positionY"
        static let borderWidth = "SelfieOverlay.borderWidth"
        static let borderHue = "SelfieOverlay.borderHue"
    }

    private let defaults: UserDefaults

    @Published public var shape: BubbleShape {
        didSet { defaults.set(shape.rawValue, forKey: Key.shape) }
    }

    @Published public var mirror: Bool {
        didSet { defaults.set(mirror, forKey: Key.mirror) }
    }

    /// 0.2 ... 1.0
    @Published public var opacity: Double {
        didSet { defaults.set(opacity, forKey: Key.opacity) }
    }

    /// Side length in points. Stored as a square; bubble is always 1:1.
    @Published public var size: CGFloat {
        didSet { defaults.set(Double(size), forKey: Key.size) }
    }

    /// Top-left position in the overlay window's coordinate space.
    @Published public var position: CGPoint {
        didSet {
            defaults.set(Double(position.x), forKey: Key.positionX)
            defaults.set(Double(position.y), forKey: Key.positionY)
        }
    }

    /// 0 ... 8
    @Published public var borderWidth: CGFloat {
        didSet { defaults.set(Double(borderWidth), forKey: Key.borderWidth) }
    }

    /// 0 ... 1 hue for the bubble border.
    @Published public var borderHue: Double {
        didSet { defaults.set(borderHue, forKey: Key.borderHue) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let rawShape = defaults.string(forKey: Key.shape) ?? BubbleShape.circle.rawValue
        self.shape = BubbleShape(rawValue: rawShape) ?? .circle
        self.mirror = defaults.object(forKey: Key.mirror) as? Bool ?? true
        self.opacity = defaults.object(forKey: Key.opacity) as? Double ?? 1.0
        self.size = CGFloat(defaults.object(forKey: Key.size) as? Double ?? 140)

        let defaultX = UIScreen.main.bounds.width - 140 - 16
        let defaultY: CGFloat = 80
        let x = CGFloat(defaults.object(forKey: Key.positionX) as? Double ?? Double(defaultX))
        let y = CGFloat(defaults.object(forKey: Key.positionY) as? Double ?? Double(defaultY))
        self.position = CGPoint(x: x, y: y)

        self.borderWidth = CGFloat(defaults.object(forKey: Key.borderWidth) as? Double ?? 2)
        self.borderHue = defaults.object(forKey: Key.borderHue) as? Double ?? 0.58
    }

    /// Reset all settings to defaults.
    public func reset() {
        shape = .circle
        mirror = true
        opacity = 1.0
        size = 140
        position = CGPoint(x: UIScreen.main.bounds.width - 140 - 16, y: 80)
        borderWidth = 2
        borderHue = 0.58
    }
}
