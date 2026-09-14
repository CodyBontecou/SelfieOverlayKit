# Android Port + Cross-Platform Unification — Exploration

Status: exploration (no implementation yet). Written against `debug-only` @ `00631ce`.

## TL;DR

- The SDK is ~3,800 lines of Swift whose weight is **UI + platform capture code** (<10% is shareable pure logic). A literal "one codebase, two platforms" (KMP or Rust core) buys very little today and adds build-system coupling.
- Recommended shape: **contract-first dual-native in a monorepo**. iOS stays Swift/SwiftPM. Android gets a Kotlin/Compose module that mirrors the public API. The *real* unification artifacts are the frozen **bubble.json schema**, the **raw-export bundle contract**, and **golden test fixtures** both sides must round-trip.
- The companion editor then consumes exports from either platform unchanged — that's the payoff that matters.
- Android port is ~2–3 weeks of focused work for parity minus `FinalCompositor` (defer; editor already owns compositing).
- Two divergences cannot be papered over and must shape the unified API: **MediaProjection's consent dialog + foreground service**, and the fact that **Android's screen capture records the bubble** (iOS's misses it), so Android must always stealth-hide during recording.

---

## 1. What the SDK actually is (platform-coupling inventory)

| Subsystem | Files | Lines (≈) | Coupling |
|---|---|---|---|
| Public API + SwiftUI modifier | `SelfieOverlayKit.swift`, `SelfieOverlayModifier.swift` | 220 | Swift-only surface |
| Overlay UI (window, bubble, ring, panel, toasts, stealth, summon) | `Overlay/*` | ~1,740 | UIKit `UIWindow` @ `.alert+1`, hit-test pass-through, SwiftUI hosted panels |
| Camera | `Camera/*` | 260 | `AVCaptureSession`, sample-buffer fan-out, 30fps lock |
| Screen recording | `RawRecorder.swift` | 182 | `RPScreenRecorder.startCapture` → `AVAssetWriter` |
| Camera recording | `CameraVideoRecorder.swift` | 161 | `AVAssetWriter`, PTS anchoring |
| Orchestration | `RecordingController.swift` | 245 | mixes both + timeline logger |
| Timeline | `BubbleTimeline.swift`, `BubbleStateLogger.swift` | 135 | pure Codable model / `CADisplayLink` sampler |
| Export + compositing | `RawExport.swift`, `FinalCompositor.swift` | 770 | FileManager, `AVAssetExportSession`, CoreImage |
| Settings | `SettingsStore.swift`, `SettingsView.swift` | 250 | UserDefaults + SwiftUI |

**Pure-logic shareable surface:** `BubbleTimeline` (model + sampling semantics), settings schema (keys/ranges/defaults), bundle layout + naming, error taxonomy. ~200 lines equivalent. Everything else is inherently platform API.

Notable existing design decisions that help the port:
- Capture-only scope: the SDK never bakes video (this branch ships a `FinalCompositor`, but the editor app owns compositing) → Android port can skip the hardest compositing work.
- Camera is already a separate track with a timeline, not baked into screen capture → the exact architecture Android needs anyway.
- Timeline is JSON, already unit-tested in isolation (`BubbleTimelineTests`).
- `debug-only` branch compiles empty in Release → Android can do the same more cleanly (see §5).

## 2. API translation map

| iOS | Android equivalent | Notes |
|---|---|---|
| `UIWindow` @ `.alert + 1` + `PassthroughWindow.hitTest` | Compose overlay at root content, or `WindowManager.addView` with `TYPE_APPLICATION_SUB_PANEL` on the activity token | In-Compose overlay floats above all app content but **not** above `Dialog`s (dialogs are separate windows). Sub-panel window gives full UIWindow parity incl. dialogs. Start with in-Compose; escalate if needed. Both are captured fine by MediaProjection. |
| `RPScreenRecorder.startCapture(handler:)` | `MediaProjection` + `VirtualDisplay` → `MediaCodec` surface | Consent dialog **per projection** + foreground service. See §3. |
| `AVCaptureSession` front cam, 30fps lock, BGRA buffers | Camera2: one shared session, `Surface` targets = preview (`TextureView`) + encoder input surface | CameraX `ImageAnalysis` can't feed an encoder surface directly; Camera2 is the right tool. Lock `CONTROL_AE_TARGET_FPS_RANGE` to 30 like iOS does. |
| `AVAssetWriter` (.mov, H.264/AAC) | `MediaCodec` + `MediaMuxer` (.mp4) | Container differs (§4). |
| Mic embedded in screen.mov + demux on export | `AudioRecord` → AAC `MediaCodec` → dedicated muxer writing `audio.m4a` directly | Android is *simpler*: no demux step exists or is needed. Screen file stays video-only. |
| `CADisplayLink` timeline sampler, rebased to first screen PTS | `Choreographer` callback sampling Compose bubble state, rebased to first encoded frame's PTS | Same host-clock trick: subtract first screen sample timestamp from snapshot times. |
| `UserDefaults` | `SharedPreferences` | Same keys, same ranges, same defaults — part of the contract. |
| `enableSummonGesture` (multi-finger tap on key window) | Root-level Compose `pointerInput` multi-pointer tap detector | Observational: must not consume touches. |
| CoreImage `FinalCompositor` | GLES shader + `MediaCodec` | **Defer.** Editor owns compositing; raw tracks + timeline already carry everything. |
| `#if DEBUG` source guards | Ship module only via `debugImplementation(...)` | Cleaner than guards: release APKs don't link the SDK at all. |

## 3. Divergences that must shape the unified API

### 3.1 MediaProjection consent + foreground service (the big one)
ReplayKit's in-app capture needs no per-recording prompt. Android's `MediaProjection` **always** shows a system consent dialog (`createScreenCaptureIntent()`), requires launching it from an `Activity` via `ActivityResultLauncher`, and the projection must run inside a foreground service (`foregroundServiceType="mediaProjection"`; Android 14 needs `FOREGROUND_SERVICE_MEDIA_PROJECTION`; Android 15 allows one projection at a time). The FGS surfaces a persistent notification while recording (needs `POST_NOTIFICATIONS` on 13+).

**API shape implication:** `startRecording()` cannot be fully self-contained on Android. Two options:

- **(a) Launcher injection (recommended):** unified API gains an optional host-provided launcher hook, e.g. `enable(context, consentLauncher: ActivityResultLauncher<Intent>?)`. iOS ignores it; Android needs it for consent. Hosts wire it once at startup — analogous to how they already wire `NSCameraUsageDescription` on iOS.
- (b) Two-phase `prepare()/startRecording()` — more "unified" on paper, worse ergonomics for 90% of hosts.

Option (a) keeps the 90% call-site (`start {}` / `stop()`) identical on both platforms.

### 3.2 Android screen capture records the bubble
iOS ships a separate camera track partly *because* ReplayKit misses high-`windowLevel` windows — screen.mov is clean by accident. MediaProjection captures the entire composited display, **including the live bubble preview** → the editor would draw the camera twice (once baked in screen track, once from camera track + timeline).

**Decision:** on Android, recording **always** enters stealth mode (bubble → tiny stop affordance; camera session + timeline keep running). The exported screen track then matches iOS semantics: clean screen + separate camera + timeline. The existing `StealthStopView` design ports directly.

### 3.3 Coordinates: points vs pixels
`bubble.json` stores bubble frames in **screen points** (iOS-specific). dp ≈ pt in spirit but not in value across devices; px differs outright. For the editor to be device- and platform-agnostic:

**Decision:** bump the schema to v2 with **normalized coordinates** (frame x/y/w/h as fractions of screen) plus `screenSize` metadata and a `schemaVersion` field. iOS v1 files remain readable; v2 is the cross-platform baseline.

### 3.4 Container formats
iOS writes `.mov` (H.264/AAC); Android naturally writes `.mp4` (same codecs). Either the contract is container-agnostic ("codecs fixed, container may be .mov/.mp4 — readers must handle both"), or iOS switches to `.mp4` for symmetry. Recommend documenting container-agnosticism now and leaving iOS as-is.

## 4. Unification options compared

### Option A — Contract-first dual-native monorepo ✅ (recommended)
Keep Swift as-is (already consumed via SPM by health-md). New Kotlin module mirrors the API. Shared artifacts:
- `shared/schema/bubble-timeline.schema.json` (v2, normalized)
- `shared/fixtures/*.json` — golden files both sides' tests must round-trip (parity is *tested*, not hoped for)
- `shared/API.md` — unified public API spec incl. documented divergences
- `shared/BUNDLE.md` — raw export bundle contract (layout, codecs, extension policy, ownership/cleanup)

Pros: zero build coupling; each platform gets the artifact it natively consumes (SPM / Gradle); matches health-md's native-per-platform architecture; the <10% shared logic is small enough that duplication is cheaper than binding ceremony. Cons: API drift risk (mitigated by golden tests + API.md review checklist).

### Option B — KMP shared core
`commonMain` holds timeline/settings/contract/state machine; `expect/actual` for the rest. Would rewrite working Swift core in Kotlin and add a Kotlin toolchain requirement to the iOS SDK build. UI and capture — the actual bulk — stay platform-specific regardless. **Not worth it at today's logic:platform ratio.** Revisit if in-SDK timeline editing or compositor logic grows.

### Option C — Rust uniFFI core
health-md already ships `healthmd-core-uniffi`, so the tooling is proven in-repo. Same trade-off as B for this codebase: binding ceremony for ~200 lines of pure logic. Same revisit trigger.

**Keeping the door open:** in both implementations, isolate pure logic (timeline model, settings schema, bundle naming) in a `Core/` folder with no platform imports. That's the seam where a KMP or Rust core gets extracted later without a rewrite.

## 5. Proposed repo layout

```
SelfieOverlayKit/
  ios/                      # SwiftPM package (current Sources/ + Tests/ move here)
  android/                  # Gradle module(s)
    selfieoverlaykit/       # the library
    sample/                 # demo app (optional)
  shared/
    schema/bubble-timeline.schema.json
    fixtures/               # golden JSON, tested from both sides
    API.md                  # unified API spec + divergence notes
    BUNDLE.md               # export bundle contract
  scripts/                  # debug-only generator (existing) + fixture checks
  .github/workflows/        # CI: iOS tests + Android lint/tests
```

Debug-only parity: Android hosts add the module via `debugImplementation` — release builds never link it (cleaner than the Swift branch's `#if DEBUG` source guards; the `debug-only` generator stays iOS-only).

## 6. Android workstreams + sizing

| # | Workstream | Size |
|---|---|---|
| 1 | Contract freeze: schema v2 (normalized + versioned), fixtures, API.md, BUNDLE.md; port iOS writer/reader to v2 | 0.5–1 d |
| 2 | Gradle module skeleton (settings, publish via maven-local/composite build), sample app | 0.5 d |
| 3 | Camera2 front session: preview Surface + encoder Surface, 30fps lock, lifecycle (bg/fg) | 2–3 d |
| 4 | Compose overlay: bubble (drag/pinch/dbl-tap/long-press, edge snap), action ring, config panel, toasts, stealth stop, summon gesture; settings store + persistence | 3–4 d |
| 5 | MediaProjection FGS: consent flow via injected launcher, VirtualDisplay → screen encoder at device res | 2–3 d |
| 6 | Mic: `AudioRecord` → AAC → `audio.m4a` muxer | 1 d |
| 7 | Timeline logger (Choreographer) + JSON codec + golden-fixture parity tests | 1 d |
| 8 | RecordingController port: orchestration, timestamp anchoring (first encoded screen frame as t0 for both tracks + snapshots), export bundling | 1 d |
| 9 | health-md integration: `DebugSelfie.kt` twin, permissions block in debug manifest | 0.5 d |
| 10 | `FinalCompositor` (GLES) | **defer** — editor owns compositing |

**Total ≈ 12–14 focused days.**

Android manifest additions (host app, debug source set): `CAMERA`, `RECORD_AUDIO`, `POST_NOTIFICATIONS` (runtime), `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PROJECTION`.

## 7. health-md integration story (the "droppable" bar)

Apple today: SPM checkout + `DebugSelfie.install()` (3-tap/2-finger summon). Android target is symmetric:

```kotlin
// debugImplementation(project(":selfieoverlaykit")) — or coordinates once published
object DebugSelfie {
    fun install(activity: ComponentActivity) {
        val overlay = SelfieOverlayKit.get(context)
        val consent = activity.registerForActivityResult(
            StartActivityForResult()) { r -> overlay.onConsentResult(r) }
        overlay.enableSummonGesture(taps = 3, touches = 2)
        overlay.onRawExportComplete = { bundle -> /* same shape as Swift */ }
        overlay.onRawExportFailed = { e -> /* same taxonomy */ }
    }
}
```

Note `registerForActivityResult` must be called before `STARTED`, so `install()` moves from "any init" (Swift) to "onCreate" (Kotlin) — document in API.md.

The export bundle lands under app-scoped external storage (maps to `RawExportLocation.documents`; "Files app" visibility has no exact Android analog — document the mapping).

## 8. Risks

- **Encoder/timestamp alignment.** iOS needed PTS anchoring to avoid 2–3s camera pre-roll. Android muxer timestamps are ours to set (µs, from `System.nanoTime()` of encoded buffers); the same rebasing must be tested for drift on long recordings.
- **Device matrix.** Camera2 + concurrent surface targets and MediaProjection behavior vary by OEM. Golden tests cover logic, not capture; budget emulator + 1–2 physical device QA.
- **API drift between the two SDKs.** Mitigate: golden fixtures + API.md as review checklist in CI.
- **Compose overlay vs Dialogs.** If in-Compose overlay proves insufficient (bubble must float above app dialogs), the sub-panel window path is the escape hatch — scoped to workstream 4, not architecture.
- **Projection exclusivity (Android 15).** One projection at a time system-wide; fail gracefully with the existing `.recordingUnavailable` error.
