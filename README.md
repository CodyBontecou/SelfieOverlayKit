# SelfieOverlayKit

Drop-in iOS SDK that floats a draggable front-camera "selfie" bubble over any host app's UI, with ReplayKit-based screen + selfie recording.

Useful for streamers, creators, reaction videos, tutorials, demos — any time you want a live POV cam overlaid on your app without leaving it.

## Features

- Live front-camera bubble that floats above your app's UI
- Drag to move, pinch to resize, double-tap to cycle shapes (circle / rounded / square), long-press for settings
- Auto-pauses camera when the app backgrounds, resumes on return
- Edge-snap on drag release
- Mirror (selfie view), opacity, size, border color/width
- Position and appearance persist across launches
- ReplayKit screen + selfie recording with native preview/trim/share sheet
- Zero config beyond two Info.plist keys

## Requirements

- iOS 15.0+
- Swift 5.9+
- Xcode 15+

## Footprint

Pure Swift, no bundled assets, no third-party dependencies. Only links system frameworks (AVFoundation, ReplayKit, SwiftUI, UIKit, CoreImage) that already ship with iOS.

- **Source**: ~6,200 lines across 42 files (~320 KB)
- **Added to host app binary**: typically ~400 KB – 1 MB after App Store thinning
- **Runtime**: no ML models, no fonts, no images

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/CodyBontecou/SelfieOverlayKit.git", from: "0.1.0")
]
```

Or in Xcode: **File → Add Package Dependencies** → paste `https://github.com/CodyBontecou/SelfieOverlayKit.git`.

## Setup

Add to your host app's `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Shows a live selfie overlay while you use the app.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Records audio during screen recording.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Saves finished recordings to your photo library.</string>
```

## Usage

### SwiftUI

```swift
import SelfieOverlayKit

struct ContentView: View {
    @State private var overlayOn = false
    @State private var showSettings = false

    var body: some View {
        YourAppContent()
            .toolbar {
                Toggle("Selfie", isOn: $overlayOn)
                Button("Customize") { showSettings = true }
            }
            .selfieOverlay(enabled: $overlayOn)
            .sheet(isPresented: $showSettings) {
                SelfieOverlaySettingsView()
            }
    }
}
```

### UIKit

```swift
import SelfieOverlayKit

// Toggle overlay
SelfieOverlayKit.shared.toggle { result in
    if case .failure(let error) = result {
        print("Overlay error:", error)
    }
}

// Present built-in settings
SelfieOverlayKit.shared.presentSettings(from: self)
```

### Recording

```swift
// Start
SelfieOverlayKit.shared.startRecording { result in
    // handle start errors
}

// Stop — presents system preview/trim/share sheet
SelfieOverlayKit.shared.stopRecording(presenter: self) { result in
    // handle stop errors
}
```

Recording captures the host app's UI **and** the selfie overlay together, thanks to ReplayKit. Users can trim, save, or share the result from the system preview sheet.

## Public API

| Symbol | Purpose |
|---|---|
| `SelfieOverlayKit.shared.start(completion:)` | Request camera permission, show overlay |
| `SelfieOverlayKit.shared.stop()` | Hide overlay, stop camera |
| `SelfieOverlayKit.shared.toggle(completion:)` | Flip visibility |
| `SelfieOverlayKit.shared.isVisible` | Bool |
| `SelfieOverlayKit.shared.settings` | `SettingsStore` (`ObservableObject`) |
| `SelfieOverlayKit.shared.presentSettings(from:)` | Present built-in SwiftUI settings sheet |
| `SelfieOverlayKit.shared.startRecording(withMicrophone:completion:)` | Begin ReplayKit recording |
| `SelfieOverlayKit.shared.stopRecording(presenter:completion:)` | Stop and show system preview |
| `SelfieOverlayKit.shared.isRecording` | Bool |
| `.selfieOverlay(enabled: Binding<Bool>)` | SwiftUI view modifier |
| `SelfieOverlaySettingsView()` | Public SwiftUI settings view |

Settings you can bind to directly on `SelfieOverlayKit.shared.settings`: `shape`, `mirror`, `opacity`, `size`, `position`, `borderWidth`, `borderHue`.

## Gestures

| Gesture | Action |
|---|---|
| Drag | Move bubble (snaps to nearest edge on release) |
| Pinch | Resize (80–320 pt) |
| Double-tap | Cycle shape: circle → rounded → square |
| Long-press | Open settings sheet |

## Architecture

The bubble is attached as a subview of the host app's key `UIWindow`, so it's always part of the rendered screen composite — including ReplayKit's recording output. It uses `AVCaptureVideoPreviewLayer` under the hood, backed by a single shared `AVCaptureSession` on the front camera.

## License

MIT — see [LICENSE](LICENSE).
