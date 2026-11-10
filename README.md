# FastShot · native macOS

Capture a region, visible window or display, annotate it, permanently redact sensitive pixels, and copy or save. Native SwiftUI + AppKit, ScreenCaptureKit, Core Graphics/Core Image and on-device Vision. Original reference logo, menu-bar mark, annotation font, neutral settings layout and compact capture controls are bundled locally.

The complete product requirements and acceptance gates are in [docs/PRD-macOS.md](docs/PRD-macOS.md). The reference lives in the ignored `reference-design/fastshot` folder and is not needed to build.

## Build and run

Requires Xcode with Swift 6.2 or newer; deployment target macOS 14. Open `FastShot.xcodeproj` and run the FastShot scheme. For a local development build without an Apple developer team:

```sh
xcodebuild -project FastShot.xcodeproj -scheme FastShot -configuration Release \
  -derivedDataPath .build-xcode CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build
open .build-xcode/Build/Products/Release/FastShot.app
```

The app uses an ad hoc signature for local testing. Developer ID signing and notarization are separate release steps. This direct-distribution utility runs without App Sandbox so its default save location is the user's actual `Documents/FastShot`, matching the reference. macOS screen-recording and Files & Folders permissions still apply. Selected save folders are persisted with bookmarks. No network client, account or telemetry is included.

## Use

Start with **⌘⇧9**, the menu-bar logo, or Region/Window/Display in the main window. Grant Screen & System Audio Recording access when needed, then retry (relaunch if macOS asks). Drag to select; a click can select a visible window. Regions stay within one display. Selection can move/resize before annotations are added. Window mode captures the visible display rectangle, including any occluding content; protected and minimized windows are not supported.

Use V to select/move, P pen, L line, A arrow, R rectangle, E ellipse, H highlighter, T text, N numbered step, X redact, B blur, M pixelate. Double-click text with Select to edit it; Return commits and Escape cancels text editing. The style controls adjust colour, stroke, text size and effect strength; their tooltips name each control. Select an existing item to change its style or move/delete it.

**⌘C** copies an image, **⌘⇧C** copies recognized text, **⌘S** opens Save As, **⌘⇧S** quick saves. **⌘Z / ⌘⇧Z** undo/redo; Escape cancels capture. Quick save never overwrites an existing file. Closing the window keeps the menu-bar app running by default. Preferences are saved automatically.

Solid Redact fills are applied after all effects and annotations, using the same fresh raster for image copy, PNG/JPEG and OCR. Blur and pixelation are cosmetic. PNG preserves exact filled pixels; JPEG compression can affect boundaries. No original source metadata or editing layers are carried into exported images; ImageIO may add structural colour/dimension fields. Clipboard managers can retain copied output.

## Validation

```sh
swift test
# Optional native view snapshots using synthetic content (no screen permission needed):
FASTSHOT_SNAPSHOT_DIR=/tmp/fastshot-native-qa swift test
```

Tests cover reverse-drag/mixed-scale crop math, annotation translation, undo branching, unsafe filename rejection, quick-save collisions, actual pointer/key editing, native view rendering, image orientation, PNG/JPEG decoding, effect application, opaque redaction-last pixels, structural metadata and OCR of sanitized pixels. See [docs/VALIDATION.md](docs/VALIDATION.md) for results and outstanding physical-device checks.
