import SwiftUI

public extension View {

    /// Binds the selfie overlay's visibility to a SwiftUI boolean.
    /// The host app must declare `NSCameraUsageDescription` in Info.plist.
    ///
    /// ```swift
    /// @State private var overlayOn = false
    /// ContentView().selfieOverlay(enabled: $overlayOn)
    /// ```
    func selfieOverlay(enabled: Binding<Bool>) -> some View {
        modifier(SelfieOverlayModifier(enabled: enabled))
    }
}

private struct SelfieOverlayModifier: ViewModifier {
    @Binding var enabled: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: enabled) { newValue in
                if newValue {
                    SelfieOverlayKit.shared.start { result in
                        if case .failure = result {
                            enabled = false
                        }
                    }
                } else {
                    SelfieOverlayKit.shared.stop()
                }
            }
            .onAppear {
                if enabled && !SelfieOverlayKit.shared.isVisible {
                    SelfieOverlayKit.shared.start { result in
                        if case .failure = result {
                            enabled = false
                        }
                    }
                }
            }
    }
}
