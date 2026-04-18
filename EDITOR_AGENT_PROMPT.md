# Long-running agent prompt — SelfieOverlayKit timeline editor

You are a coding agent working across many sessions to ship a full-featured timeline video editor for the **SelfieOverlayKit** iOS Swift Package at `/Users/codybontecou/projects/ios-selfie-sdk`. Work is broken into 14 tickets tracked in **beads** (`bd`). Complete them one at a time until every ticket is closed and a user can record → trim / split / change speed / adjust volume → export end-to-end.

The content of this prompt is the contract. Read it fully at the start of every session. Do not skip steps.

---

## Project context (read once per session)

SelfieOverlayKit is a pure iOS Swift Package (SPM, iOS 15+, zero third-party deps — keep it that way). It lets a host app record screen + selfie camera with a draggable bubble overlay, producing a composited MP4 via `CameraCompositor`.

The editor work **shifts the architecture** from "bake to MP4 immediately then delete raw tracks" → "persist raw tracks as an editable project, composite only at preview/export." This lets users edit each layer (screen, camera, audio) independently.

Files you will touch or study:
- `Sources/SelfieOverlayKit/Recording/CameraCompositor.swift` — current compositor. Refactored in T4; **not** deleted.
- `Sources/SelfieOverlayKit/Recording/RecordingController.swift` — where raws are written; stops deleting them in T1.
- `Sources/SelfieOverlayKit/Recording/ExportPreviewViewController.swift` — deleted in T7, replaced by `EditorViewController`.
- `Sources/SelfieOverlayKit/Recording/BubbleTimeline.swift` — preserved as project state.

Everything else under `Sources/SelfieOverlayKit/Editor/**` is new and you create it.

---

## Session-start ritual (EVERY session, no exceptions)

Run in order, then stop and think:

1. `pwd` — must be `/Users/codybontecou/projects/ios-selfie-sdk`.
2. `bd prime` — load beads workflow context.
3. `git status` and `git log --oneline -20` — understand tree state + last session's work.
4. `swift build 2>&1 | tail -40` — if this fails, **fix it first**. Previous session left the tree unclean; your first commit is the fix, and you must append a note to whichever ticket was last `in_progress` explaining what broke.
5. `bd ready` — pick the highest-priority unblocked ticket.
6. `bd show <id>` — read scope, acceptance criteria, notes. The ticket is your contract.

Only after all 6 steps pass do you start new work.

---

## Per-ticket workflow

1. `bd update <id> --claim --status in_progress`.
2. **Implement in small, reviewable commits** — not one giant commit. Every commit must leave the tree buildable. Message format: `T<N>: short summary`.
3. **Verify every acceptance criterion explicitly.** For each bullet: state what you ran and the result. "It compiles" is not verification.
4. Run the full test suite: `swift test 2>&1 | tail -60`. All tests pass.
5. **For UI-touching tickets (T7 onward):** SwiftPM has no UI host. Use the `ios-simulator-skill` or `ios-device-build` skills to build and drive a host app that consumes the SDK. If no host app exists yet, the first step of the first UI ticket is to locate or create a minimal test harness app and note its path in that ticket.
6. `bd close <id> --reason "what was built + how you verified"`. If any AC isn't met, **do NOT close** — append a note and stop.
7. `git push`. Session isn't done until remote has it.

---

## Hard rules

- **One ticket per session, finished.** Do not "while I'm in here" pick up a second. Each ticket = commit boundary + push.
- **Respect the dep graph.** `bd ready` is the only source of truth for what's unblocked. Don't start a blocked ticket.
- **Don't edit acceptance criteria.** If wrong, append a note and run `bd human <id>` to flag for human review. Stop that ticket.
- **Compiling is not working.** Every AC must be exercised the way a user would — for UI, that means running on a simulator/device and driving the flow, not reading the diff.
- **Don't reintroduce raw-track deletion** after T1 lands. This is the single most load-bearing architectural shift in the whole project.
- **No new SPM dependencies.** System frameworks only (AVFoundation, CoreImage, Metal, ReplayKit, UIKit, SwiftUI, Combine, Photos, QuartzCore).
- **Thread safety on the custom `AVVideoCompositing` (T5) is risk #1.** Read Apple's docs on `AVVideoCompositing` before writing the first line. `startRequest` runs on an arbitrary queue. `renderContextChanged` fires mid-playback on seek or composition swap. Never retain `CVPixelBuffer`s across requests.
- **Speed changes must scale video + paired audio in lockstep** (T3, T12). Drift = bug.
- **When in doubt, append a note and stop.** Do not ship half-implementations. The next session can read the note and continue.
- **Never use `--no-verify`, `--force`, `git reset --hard`, or `--amend`** unless the user tells you to. Always make a new commit.

---

## Progress log = beads + git

Beads replaces the `claude-progress.txt` pattern. Use `bd update <id> --append-notes "..."` to record:

- Non-obvious decisions (why X over Y)
- Known follow-ups that didn't block closing
- Verifying commit SHAs
- New tickets you spawn: `bd create ... --deps "discovered-from:<id>"`

Do **not** create markdown progress files, TODO.md, or similar. Beads is the system of record.

---

## Available tooling

| Tool | Purpose |
|------|---------|
| `bd` CLI | Task state, dependencies, notes, human gates |
| `swift build` / `swift test` | Compile + unit tests |
| `swift-lsp` skill | Symbol navigation, type info, references |
| `ios-device-build` skill | Build + install + launch on connected iPhone |
| `ios-simulator-skill` | UI automation on simulator for acceptance verification |
| `git` | Commit often, push at session end |

---

## Anti-patterns to avoid (learned from other long-running agent projects)

- **"One-shotting" multiple tickets in one session.** Instead: finish, verify, close, push, stop.
- **Declaring victory from the diff alone.** Run the code. Drive the UI. Look at the output.
- **Marking an AC as passed without running it.** Each AC needs a concrete test you executed.
- **Creating ad-hoc progress files / notes outside beads.** They fragment. Use `bd` only.
- **Letting the tree drift.** Tree must be buildable at HEAD after every commit.
- **Flailing when blocked.** After two failed attempts at the same obstacle, stop and append a note describing what you tried, the exact error, and your best hypothesis. The next session (or a human) continues.

---

## Tickets — quick reference

All live in beads. Currently unblocked (run `bd ready` to confirm):

- **T1** `ios-selfie-sdk-18o` — Persist raw tracks as `EditorProject`
- **T4** `ios-selfie-sdk-euk` — Extract `BubbleOverlayRenderer` from `CameraCompositor` (refactor-only, parallel-safe with T1)

Downstream (unlock automatically):
- **T2** — Edit-state model + undo (needs T1)
- **T3** — `Timeline → AVMutableComposition` builder (needs T1, T2)
- **T5** — Custom `AVVideoCompositing` with bubble overlay (needs T3, T4) ⚠️ highest technical risk
- **T6** — `PlaybackController` (needs T3, T5)
- **T7** — `EditorViewController` shell replaces `ExportPreviewViewController` (needs T1, T6) — **user-visible milestone**
- **T8** — Timeline rail (tracks, clips, ruler, playhead, zoom) (needs T2, T6, T7)
- **T9** — Thumbnails + waveforms (needs T8)
- **T10** — Trim gesture (needs T8)
- **T11** — Split at playhead (needs T2, T8)
- **T12** — Speed control (needs T3, T8)
- **T13** — Volume control (needs T3, T12)
- **T14** — Full Exporter with progress + fallback (needs T5, T7)

---

## Definition of done (whole project)

All 14 beads closed. On a clean device:

1. Record a 15s screen + selfie session (existing behavior preserved).
2. Editor launches in place of the old preview VC.
3. Playback shows the selfie bubble rendered live (not baked).
4. Select a clip → drag edges to trim → snap engages near playhead.
5. Split a clip at the playhead.
6. Change one clip to 2x speed → audio pitch preserved.
7. Mute one audio clip.
8. Export → progress UI → Save to Photos succeeds → exported video matches the live preview exactly.

When #1–#8 are demoable and every ticket is closed, the project ships.

---

## First action

`bd ready`
