# SelfieOverlayKit

Drop-in iOS SDK that floats a draggable front-camera "selfie" bubble over any host app's UI and captures the session as raw screen + camera + audio tracks for downstream editing.

Useful for streamers, creators, reaction videos, tutorials, demos — any time you want a live POV cam overlaid on your app, then hand the footage to a real editor (the companion short-form editor app, or any NLE) without leaving it.

## Scope

SelfieOverlayKit is **capture-only**. It:

- shows the selfie bubble,
- records the host app's screen + the selfie camera + optional mic audio,
- exports the four raw files (`screen.mov`, `camera.mov`, `audio.m4a`, `bubble.json`) to a caller-supplied directory.

Compositing, templating, trimming, and rendering short-form videos live in a separate standalone app that ingests the raw export bundle. The SDK itself never bakes a final video.

## Features

- Live front-camera bubble that floats above your app's UI
- Drag to move, pinch to resize, double-tap to cycle shapes (circle / rounded / square), long-press for settings
- Auto-pauses camera when the app backgrounds, resumes on return
- Edge-snap on drag release
- Mirror (selfie view), opacity, size, border color/width
- Position and appearance persist across launches
- ReplayKit screen + front-camera + mic recording
- Raw export: screen/camera/audio/bubble-timeline files in a caller-chosen directory
- Zero third-party dependencies

## Requirements

- iOS 15.0+
- Swift 5.9+
- Xcode 15+

## Footprint

Pure Swift, no bundled assets, no third-party dependencies. Only links system frameworks (AVFoundation, ReplayKit, SwiftUI, UIKit, CoreImage) that already ship with iOS.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/CodyBontecou/SelfieOverlayKit.git", from: "0.4.0")
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
```

If you want the exported files to surface in the Files app under "On My iPhone → [App Name]", also add:

```xml
<key>UIFileSharingEnabled</key>
<true/>
<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
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

### Recording + raw export

```swift
// Optional: get notified when the bubble's stop control completes a raw export.
SelfieOverlayKit.shared.onRawExportComplete = { bundle in
    // bundle.screenURL, bundle.cameraURL, bundle.audioURL, bundle.bubbleTimelineURL
}
SelfieOverlayKit.shared.onRawExportFailed = { error in
    // surface to the user
}

SelfieOverlayKit.shared.startRecording { _ in }

// Driven from your own UI:
let destination = yourDocumentsDirectory.appendingPathComponent("recordings/\(UUID().uuidString)")
SelfieOverlayKit.shared.stopRecording(exportTo: destination, demuxAudio: true) { result in
    switch result {
    case .success(let bundle):
        // hand bundle to the editor app / share sheet / your own pipeline
    case .failure(let error):
        print("Raw export failed:", error)
    }
}
```

The bundle layout is:

```
<destination>/
  screen.mov   // ReplayKit screen capture (video-only when demuxAudio=true)
  camera.mov   // Front-camera selfie, video-only
  audio.m4a    // Demuxed mic audio (absent when recorded without mic)
  bubble.json  // Bubble position/size/shape/mirror/opacity samples over time
```

Pass `demuxAudio: false` to leave the mic embedded in `screen.mov` and skip writing `audio.m4a`.

### Raw export from the bubble's stop control

The bubble's config panel and stealth stop button route through the raw-export path automatically. Where the files land depends on `SelfieOverlayKit.shared.settings.rawExportLocation`:

- `.documents` (default) — `Documents/SelfieOverlayKit/RawExports/<uuid>/`. Visible in the Files app when the host opts into file sharing.
- `.applicationSupport` — `Application Support/SelfieOverlayKit/RawExports/<uuid>/`. Sandboxed, never user-visible.

## Public API

| Symbol | Purpose |
|---|---|
| `SelfieOverlayKit.shared.start(completion:)` | Request camera permission, show overlay |
| `SelfieOverlayKit.shared.stop()` | Hide overlay, stop camera |
| `SelfieOverlayKit.shared.toggle(completion:)` | Flip visibility |
| `SelfieOverlayKit.shared.isVisible` | Bool |
| `SelfieOverlayKit.shared.enableSummonGesture(taps:touches:)` | Install global multi-finger tap toggle |
| `SelfieOverlayKit.shared.disableSummonGesture()` | Remove summon gesture |
| `SelfieOverlayKit.shared.settings` | `SettingsStore` (`ObservableObject`) |
| `SelfieOverlayKit.shared.presentSettings(from:)` | Present built-in SwiftUI settings sheet |
| `SelfieOverlayKit.shared.startRecording(withMicrophone:completion:)` | Begin ReplayKit recording |
| `SelfieOverlayKit.shared.stopRecording(exportTo:demuxAudio:completion:)` | Stop and write raw bundle to `destination` |
| `SelfieOverlayKit.shared.onRawExportComplete` | Callback for bubble-initiated raw exports |
| `SelfieOverlayKit.shared.onRawExportFailed` | Callback for bubble-initiated raw export errors |
| `SelfieOverlayKit.shared.isRecording` | Bool |
| `RawExportBundle` | `screenURL`, `cameraURL`, `audioURL?`, `bubbleTimelineURL`, `duration` |
| `.selfieOverlay(enabled: Binding<Bool>)` | SwiftUI view modifier |
| `SelfieOverlaySettingsView()` | Public SwiftUI settings view |

Settings on `SelfieOverlayKit.shared.settings`: `shape`, `mirror`, `opacity`, `size`, `position`, `borderWidth`, `borderHue`, `hideDuringRecording`, `rawExportLocation`.

## Gestures

| Gesture | Action |
|---|---|
| Drag | Move bubble (snaps to nearest edge on release) |
| Pinch | Resize (80–320 pt) |
| Double-tap | Cycle shape: circle → rounded → square |
| Tap | Open action ring (edit / close) |
| Long-press edit | Open inline settings panel |

## Architecture

The bubble lives in a dedicated `UIWindow` at `.alert + 1` so it floats above modally-presented sheets while remaining part of the scene's screen-capture composite. Recording keeps the screen and front-camera streams in **separate** `.mov`s: ReplayKit's in-app capture misses secondary windows at high `windowLevel`s, so the selfie is captured independently via `AVCaptureSession` and composited downstream (in the companion editor app or a host-chosen NLE).

## License

MIT — see [LICENSE](LICENSE).
