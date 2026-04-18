import SwiftUI
import UIKit

/// Drives the show/hide animation of the radial action ring around the bubble.
/// Held by the controller so it can flip `visible` to dismiss with the same spring
/// animation that brought the icons in.
final class BubbleActionRingState: ObservableObject {
    @Published var visible: Bool = false
}

/// Tiny radial menu shown around the bubble on tap. Two satellite buttons fly out
/// from the bubble center: an X to turn the camera off and a pencil to open the
/// full config panel.
struct BubbleActionRing: View {

    enum Placement {
        /// Icons sit on the upper arc — used when the bubble has room above it.
        case top
        /// Icons sit on the lower arc — used when the bubble is near the top edge.
        case bottom
    }

    static let iconSize: CGFloat = 36
    static let edgeGap: CGFloat = 14

    /// Total width/height of the square that houses the bubble plus the satellites.
    static func containerSize(bubbleSize: CGFloat) -> CGFloat {
        bubbleSize + 2 * (edgeGap + iconSize)
    }

    /// Centers (in container-local coordinates) where the satellite icons land
    /// after animating in. The controller uses these to mask hit-testing so taps
    /// outside the icons fall through to the bubble or dismiss catcher.
    static func iconCenters(bubbleSize: CGFloat, placement: Placement) -> [CGPoint] {
        let radius = bubbleSize / 2 + edgeGap + iconSize / 2
        let side = containerSize(bubbleSize: bubbleSize)
        let center = CGPoint(x: side / 2, y: side / 2)
        return angles(for: placement).map { degrees in
            let radians = degrees * .pi / 180
            let dx = CGFloat(Double(radius) * cos(radians))
            let dy = CGFloat(Double(radius) * sin(radians))
            return CGPoint(x: center.x + dx, y: center.y + dy)
        }
    }

    private static func angles(for placement: Placement) -> [Double] {
        switch placement {
        case .top:    return [-135, -45]   // upper-left (X), upper-right (pencil)
        case .bottom: return [135, 45]
        }
    }

    @ObservedObject var state: BubbleActionRingState
    let bubbleSize: CGFloat
    let placement: Placement
    let onClose: () -> Void
    let onEdit: () -> Void

    private var radius: CGFloat {
        bubbleSize / 2 + Self.edgeGap + Self.iconSize / 2
    }

    private var side: CGFloat {
        Self.containerSize(bubbleSize: bubbleSize)
    }

    var body: some View {
        let angles = Self.angles(for: placement)
        ZStack {
            satellite(systemName: "xmark",
                      tint: .red,
                      angleDegrees: angles[0],
                      action: onClose)
            satellite(systemName: "pencil",
                      tint: .accentColor,
                      angleDegrees: angles[1],
                      action: onEdit)
        }
        .frame(width: side, height: side)
        .animation(.spring(response: 0.34, dampingFraction: 0.66), value: state.visible)
    }

    private func satellite(systemName: String,
                           tint: Color,
                           angleDegrees: Double,
                           action: @escaping () -> Void) -> some View {
        let radians = angleDegrees * .pi / 180
        let r: Double = state.visible ? Double(radius) : 0
        let offset = CGSize(width: CGFloat(r * cos(radians)),
                            height: CGFloat(r * sin(radians)))

        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .offset(offset)
        .scaleEffect(state.visible ? 1 : 0.3)
        .opacity(state.visible ? 1 : 0)
    }
}

/// Container the action ring is hosted inside. Its frame straddles the bubble so
/// the satellites can render around it, but only taps that land on an icon are
/// captured — everything else (including taps on the bubble itself) falls through.
final class BubbleActionRingContainerView: UIView {

    /// Centers of the icon hit targets in this view's coordinate space.
    var iconCenters: [CGPoint] = []
    /// Hit radius around each icon center — slightly larger than the visual icon.
    var iconHitRadius: CGFloat = BubbleActionRing.iconSize / 2 + 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let inIcon = iconCenters.contains {
            hypot(point.x - $0.x, point.y - $0.y) <= iconHitRadius
        }
        guard inIcon else { return nil }
        return super.hitTest(point, with: event)
    }
}
