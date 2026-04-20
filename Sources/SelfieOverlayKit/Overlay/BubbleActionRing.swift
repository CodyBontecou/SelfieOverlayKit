import SwiftUI
import UIKit

/// Drives the show/hide animation of the radial action ring around the bubble.
/// Held by the controller so it can flip `visible` to dismiss with the same spring
/// animation that brought the icons in.
final class BubbleActionRingState: ObservableObject {
    @Published var visible: Bool = false
}

/// Tiny side menu shown around the bubble on tap. Two buttons fly out from
/// the bubble center and stack along one axis: an X to turn the camera off,
/// and a pencil to open the full config panel. The stack axis flips between
/// vertical (left/right placement) and horizontal (top/bottom placement) so
/// the icons stay on-screen even when the bubble is sized up to fill the
/// screen width.
struct BubbleActionRing: View {

    enum Placement {
        /// Icons stack vertically on the left side of the bubble — used when
        /// the bubble is near the right edge of the screen.
        case left
        /// Icons stack vertically on the right side of the bubble — used when
        /// the bubble is near the left edge of the screen.
        case right
        /// Icons stack horizontally above the bubble — used when the bubble
        /// is too wide for horizontal placement and sits near the bottom.
        case top
        /// Icons stack horizontally below the bubble — used when the bubble
        /// is too wide for horizontal placement and sits near the top.
        case bottom
    }

    static let iconSize: CGFloat = 36
    static let edgeGap: CGFloat = 14
    /// Offset of each icon from the stack midpoint, along whichever axis the
    /// icons stack on (vertical for left/right, horizontal for top/bottom).
    static let stackOffset: CGFloat = iconSize / 2 + 4

    /// Total width/height of the square that houses the bubble plus the satellites.
    static func containerSize(bubbleSize: CGFloat) -> CGFloat {
        bubbleSize + 2 * (edgeGap + iconSize)
    }

    /// Centers (in container-local coordinates) where the icons land after
    /// animating in. Order is [xmark, pencil] — for left/right placement
    /// xmark sits above pencil; for top/bottom placement xmark sits to the
    /// left of pencil. The controller uses these to mask hit-testing so taps
    /// outside the icons fall through to the bubble or dismiss catcher.
    static func iconCenters(bubbleSize: CGFloat, placement: Placement) -> [CGPoint] {
        let side = containerSize(bubbleSize: bubbleSize)
        let center = CGPoint(x: side / 2, y: side / 2)
        let primary = bubbleSize / 2 + edgeGap + iconSize / 2
        switch placement {
        case .left, .right:
            let dx = primary * (placement == .right ? 1 : -1)
            return [
                CGPoint(x: center.x + dx, y: center.y - stackOffset),
                CGPoint(x: center.x + dx, y: center.y + stackOffset),
            ]
        case .top, .bottom:
            let dy = primary * (placement == .bottom ? 1 : -1)
            return [
                CGPoint(x: center.x - stackOffset, y: center.y + dy),
                CGPoint(x: center.x + stackOffset, y: center.y + dy),
            ]
        }
    }

    @ObservedObject var state: BubbleActionRingState
    let bubbleSize: CGFloat
    let placement: Placement
    let onClose: () -> Void
    let onEdit: () -> Void

    private var side: CGFloat {
        Self.containerSize(bubbleSize: bubbleSize)
    }

    var body: some View {
        let centers = Self.iconCenters(bubbleSize: bubbleSize, placement: placement)
        let bubbleCenter = CGPoint(x: side / 2, y: side / 2)
        ZStack {
            satellite(systemName: "xmark",
                      tint: .red,
                      target: centers[0],
                      bubbleCenter: bubbleCenter,
                      action: onClose)
            satellite(systemName: "pencil",
                      tint: .primary,
                      target: centers[1],
                      bubbleCenter: bubbleCenter,
                      action: onEdit)
        }
        .frame(width: side, height: side)
        .animation(.spring(response: 0.34, dampingFraction: 0.66), value: state.visible)
    }

    private func satellite(systemName: String,
                           tint: Color,
                           target: CGPoint,
                           bubbleCenter: CGPoint,
                           action: @escaping () -> Void) -> some View {
        let fullOffset = CGSize(width: target.x - bubbleCenter.x,
                                height: target.y - bubbleCenter.y)
        let offset = state.visible ? fullOffset : .zero

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
