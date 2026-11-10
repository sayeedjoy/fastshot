# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

FastShot is a native macOS (14+) menu-bar screenshot utility: capture a region/window/display, annotate, permanently redact, then copy, save, or OCR. SwiftUI + AppKit, ScreenCaptureKit, Core Graphics/Core Image, on-device Vision. No network code, accounts, or telemetry.

## Commands

```sh
swift build                      # SwiftPM build (debug)
swift test                       # run all tests (Swift Testing, not XCTest)
swift test --filter RendererTests                                   # one suite
swift test --filter "RendererTests/redactionLastAndLosslessRoundtrip"  # one test
FASTSHOT_SNAPSHOT_DIR=/tmp/fastshot-native-qa swift test            # also writes settings.png / overlay.png view snapshots

# App bundle build (ad hoc signed, no developer team needed)
xcodebuild -project FastShot.xcodeproj -scheme FastShot -configuration Release \
  -derivedDataPath .build-xcode CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build
open .build-xcode/Build/Products/Release/FastShot.app

./scripts/install.sh   # build Release, quit + replace ~/Applications/FastShot.app, delete stale build copies, relaunch
```

There is no linter configured. Tests need no screen-recording permission (they use synthetic images and injected permission closures). Launching the app with `--request-screen-access` triggers the permission prompt explicitly; normal launches never ask.

## Two build systems, one source tree

- `Package.swift` (SwiftPM) is used for `swift build` / `swift test`. The test target lives only here — the Xcode project has no test target.
- `FastShot.xcodeproj` builds the actual `.app` (bundle ID `com.zerox.FastShot`, hardened runtime, **no App Sandbox** so the default save location is the real `~/Documents/FastShot`). It references the `FastShot/` folder as a whole, so new source files are picked up automatically by both systems.
- Both are configured for **MainActor default isolation** (SwiftPM: `.defaultIsolation(MainActor.self)` + `NonisolatedNonsendingByDefault`; Xcode: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency). Pure value types and helpers (`Annotation`, `Tool`, `Geometry`, `Filename`, `OutputFiles`, `Preferences`, `TextRecognition`…) are explicitly marked `nonisolated`; keep that pattern for new non-UI types. Off-main work uses `@concurrent` (see `TextRecognition.recognize`).
- Resource lookup differs: code branches on `#if SWIFT_PACKAGE` to use `Bundle.module` (resources under `Resources/`) vs `Bundle.main`. Follow the same pattern when loading bundled files (`AnnotationFont.ttf`, `logo.png`, `tray-template.png`).

## Architecture

**App shell** (`FastShotApp.swift`): a single `Window` (id `"settings"`, identified at the AppKit level via `WindowRegistration`) plus a `MenuBarExtra`. `AppModel` owns `PreferencesStore`, `CaptureCoordinator`, and the Carbon `GlobalShortcut` (default ⌘⇧9). `start()` enforces single-instance via an `flock` on `~/Library/Application Support/com.zerox.FastShot/instance.lock`. Closing the window keeps the app running unless `keepRunning` is off. Windows are found by `identifier == "settings"` throughout — don't rename it.

**Capture flow** (`CaptureCoordinator.swift`):
1. `begin(mode)` grabs `SCShareableContent`, then captures a frozen `CGImage` of **every** display (excluding FastShot's own windows) *before* any overlay is shown, plus on-screen layer-0 window rects (via `CGWindowListCopyWindowInfo`) as `WindowRegion`s for click-to-select-window.
2. One borderless `.screenSaver`-level `CaptureWindow`/`CaptureView` is created per screen. A `session` UUID token guards every async continuation; display changes and sleep call `cancel()`.
3. `export(view, action:)` renders once via `Renderer.render` and then copies PNG, OCRs (Vision, off main actor), Save-As (`NSSavePanel` with a PNG/JPEG accessory), or quick-saves (`OutputFiles.quickSave`, never overwrites — writes with `.withoutOverwriting` and bumps a counter). `finish(restore:)` tears down overlays and re-activates the previously frontmost app.

**Overlay editor** (`CaptureView.swift`): an AppKit `NSView` (flipped, view points) handling selection drag/resize, tool hotkeys, text editing via a temporary `NSTextField`, and the floating mode/tool/style/action bars. Annotations are stored in **source-image pixel coordinates** (`pixelPoint` converts from view points); `Geometry.pixelCrop` maps the view selection to a pixel crop. All edits go through `EditHistory.commit` (snapshot-based undo/redo; committing clears redo). The on-screen preview is itself produced by `Renderer`.

**Renderer** (`Renderer.swift`) is the single source of truth for preview, clipboard, file export, and OCR input. Ordering is a security invariant: blur/pixelate effects first → vector annotations → solid **redact fills last** (non-antialiased), so redacted pixels are opaque in every output and OCR only ever sees sanitized pixels. Encoding writes a fresh raster with no source metadata. Tests assert this ordering — preserve it.

**Preferences** (`Preferences.swift`): a `Codable` struct persisted as JSON under the `FastShot.preferences` UserDefaults key on every `didSet`. Custom save folders are stored as security-scoped bookmarks. `Filename.render` expands `{date} {time} {n} {YYYY} {MM} {DD} {hh} {mm} {ss} {width} {height}` and rejects unknown tokens, path separators, `..`, colons, and control characters.

**Settings UI** (`ContentView.swift`): SwiftUI settings window with tabs and an `NSViewRepresentable` shortcut recorder; `AppModel.recordingShortcut` suppresses the global hotkey while recording.

## Notes

- `docs/` is currently empty; the README's links to `docs/PRD-macOS.md` and `docs/VALIDATION.md` point to files not in the repo. `reference-design/` (gitignored) holds the design reference and isn't needed to build.
- Tests that touch preferences use an isolated `UserDefaults(suiteName:)` and clear it; `CaptureCoordinator` takes an injectable `permissionRequest` closure for permission tests.
