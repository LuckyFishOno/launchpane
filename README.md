# OpenLaunchpad

OpenLaunchpad is a native macOS application launcher built with Swift 6, AppKit, Core Animation, and documented system APIs.

Version 1.0 focuses on a fast, responsive launcher experience with adaptive layout, native application discovery, local search, interactive paging, persistent reordering, and folders.

## Download

[Download OpenLaunchpad for macOS](https://github.com/LuckyFishOno/open-launchpad/releases/latest/download/OpenLaunchpad.dmg)

## Installation

1. Download `OpenLaunchpad.dmg`.
2. Open the disk image.
3. Drag `Open Launchpad.app` into the `Applications` folder.
4. Launch OpenLaunchpad from `Applications`.

### First Launch

OpenLaunchpad is currently distributed without an Apple Developer ID signature or Apple notarization.

On first launch, macOS may display an **“OpenLaunchpad” Not Opened** warning because it cannot verify the application.

If this happens:

1. Click **Done**. Do not choose **Move to Trash**.
2. Open **System Settings → Privacy & Security**.
3. Scroll down to the **Security** section.
4. Find the message stating that OpenLaunchpad was blocked and click **Open Anyway**.
5. Authenticate with your password or Touch ID if requested.
6. Confirm by clicking **Open**.

After OpenLaunchpad has been allowed once, macOS will remember this choice and the application can be opened normally afterward.

This extra step is required because the current release is distributed outside the Mac App Store without Apple Developer ID notarization.

## System Requirements

- macOS 15 or later
- Apple silicon or Intel Mac

## Features

- Native AppKit and Core Animation runtime.
- Adaptive grid layout based on logical display geometry rather than hard-coded resolutions.
- Multi-display and mixed-scale support, including Retina and non-Retina displays.
- Installed-application discovery using public filesystem and bundle metadata APIs.
- Case-insensitive contiguous-substring search by application display name.
- IME-aware search presentation for marked text such as Zhuyin, Pinyin, and Japanese input.
- Fresh search state on reopening: empty query, centered placeholder, and the first application page.
- Interactive trackpad paging with direct finger tracking and smooth velocity-aware settling.
- Calmer 0.56-second wheel/keyboard paging, with one page per continuous wheel burst.
- Full-display frosted wallpaper with a visually replaced menu region and an interactive system Dock.
- Persistent drag-and-drop reordering and folder creation.
- Page-local app placement: moving an app out leaves room on that page; only overflow pushes apps into later pages.
- Multi-page dragging by holding an app at the screen edge, including a new trailing page when needed.
- Keyboard navigation and native accessibility hit targets.
- Right-to-left layout support.
- Respect for the macOS Reduce Motion setting.
- No telemetry, account, or mandatory network connection.

## App Placement and Layout Data

Pages keep their own arrangement. Removing or moving an app compacts only its
source page; it does not pull apps backward from later pages. Dropping into a
full page pushes its overflow forward, creating another page if necessary.
Keep holding the dragged app at an edge to continue through existing pages;
you do not need to leave and re-enter the edge after every turn. If you release
while a page is sliding, the drop finishes on that incoming page.

The layout file at `~/Library/Application Support/OpenLaunchpad/LauncherLayout.json`
now uses schema 2 with explicit pages. Older schema-1 layouts migrate
automatically, retaining app/folder order and revision. Before migration, the
original file is preserved as `LauncherLayout.pre-pages.backup.json` beside it;
an existing backup is never overwritten. To roll back, quit both launcher
processes, preserve the current layout separately, and restore a copy of that
backup. The backup does not contain arrangement changes made after migration.

## Build and Run

OpenLaunchpad is a native macOS application and should be built with Xcode.

The Dock opens a short-lived `OpenLaunchpad.app` launcher. Its embedded
`OpenLaunchpadAgent.app` owns the persistent UI; both use accessory activation.
Keep the entire app bundle together. The embedded `LoginItems` directory is a
packaging location, not an automatic login-item registration.

SwiftPM builds and tests the reusable core libraries, not the application bundle.

### Development Requirements

- macOS 15 or later
- Xcode 26 or later
- Swift 6
- XcodeGen 2.42 or later when regenerating the Xcode project

### Build

From the project root:

```bash
xcodebuild \
  -project OpenLaunchpad.xcodeproj \
  -scheme OpenLaunchpad \
  -configuration Debug \
  CONFIGURATION_BUILD_DIR="$PWD/Builds" \
  build
```

The application bundle will be generated directly inside the project at:

```text
Builds/OpenLaunchpad.app
```

### Run

```bash
open "$PWD/Builds/OpenLaunchpad.app"
```

### Clean Build

```bash
pkill -x OpenLaunchpad 2>/dev/null || true
pkill -x OpenLaunchpadAgent 2>/dev/null || true

xcodebuild \
  -project OpenLaunchpad.xcodeproj \
  -scheme OpenLaunchpad \
  -configuration Debug \
  CONFIGURATION_BUILD_DIR="$PWD/Builds" \
  clean build
```

### Full Reset

Use this when you want OpenLaunchpad to start from a completely clean local development state.

This removes:

- Project-local build output
- SwiftPM build artifacts
- OpenLaunchpad-specific Xcode DerivedData
- Persisted launcher layout and folders
- OpenLaunchpad preferences
- OpenLaunchpad caches
- Saved application state

It does **not** delete the source repository or Git history.

```bash
pkill -x OpenLaunchpad 2>/dev/null || true
pkill -x OpenLaunchpadAgent 2>/dev/null || true

rm -rf "$PWD/Builds"
rm -rf "$PWD/.build"

find "$HOME/Library/Developer/Xcode/DerivedData" \
  -maxdepth 1 \
  -type d \
  -name 'OpenLaunchpad-*' \
  -exec rm -rf {} +

rm -rf "$HOME/Library/Application Support/OpenLaunchpad"
rm -rf "$HOME/Library/Caches/org.openlaunchpad.OpenLaunchpad"
rm -rf "$HOME/Library/Saved Application State/org.openlaunchpad.OpenLaunchpad.savedState"

defaults delete org.openlaunchpad.OpenLaunchpad \
  2>/dev/null || true
```

Verify that the persisted launcher layout is gone:

```bash
test ! -e \
  "$HOME/Library/Application Support/OpenLaunchpad/LauncherLayout.json" \
  && echo "Launcher layout: clean"
```

Then create a completely fresh Debug build:

```bash
xcodebuild \
  -project OpenLaunchpad.xcodeproj \
  -scheme OpenLaunchpad \
  -configuration Debug \
  CONFIGURATION_BUILD_DIR="$PWD/Builds" \
  clean build
```

The freshly built app will be available at:

```text
Builds/OpenLaunchpad.app
```

Run it with:

```bash
open "$PWD/Builds/OpenLaunchpad.app"
```

### Release Build

To create an optimized Release build in the same project-local output directory:

```bash
pkill -x OpenLaunchpad 2>/dev/null || true
pkill -x OpenLaunchpadAgent 2>/dev/null || true

xcodebuild \
  -project OpenLaunchpad.xcodeproj \
  -scheme OpenLaunchpad \
  -configuration Release \
  CONFIGURATION_BUILD_DIR="$PWD/Builds" \
  clean build
```

The Release application will also be available at:

```text
Builds/OpenLaunchpad.app
```

## Test

Run the Xcode test suite:

```sh
xcodebuild \
  -project OpenLaunchpad.xcodeproj \
  -scheme OpenLaunchpad \
  test \
  CODE_SIGNING_ALLOWED=NO
```

Or run the Swift package tests:

```sh
swift test
```

The standalone AppKit search-reopening regression check and its invocation are
documented in [`Tests/Runtime/README.md`](Tests/Runtime/README.md). It covers
outside-click dismissal, rapid reopening, incomplete IME input, and restored
search appearance using an isolated layout store.

See [`docs/PAGING_PERFORMANCE.md`](docs/PAGING_PERFORMANCE.md) for paging fixes,
before/after measurements, and the limits of those measurements.

`LauncherPageLayoutTests` covers page-local gaps, forward overflow, multi-page
and reverse moves, folders, reconciliation, page-boundary-only persistence,
and schema migration/backup preservation. The cross-page change passes the
133-test Swift core suite and the Debug application build. Standalone runtime
checks cover held-edge traversal, reverse traversal, release at the edge and
during animation, cancellation, new pages, and unresolved-app index mapping.
See [`Tests/Runtime/README.md`](Tests/Runtime/README.md) to reproduce them; these
checks do not measure compositor frame pacing on every display.

## Project Structure

```text
Sources/
├── AppCore/          Application discovery, search, layout persistence, and drag state
├── DisplayCore/      Display geometry and screen resolution handling
├── LayoutCore/       Adaptive grid and folder layout solvers
├── OpenLaunchpad/    Shared AppKit/Core Animation UI and Dock launcher entry point
└── OpenLaunchpadAgent/ Embedded accessory-agent entry point

Tests/
├── AppCoreTests/
├── DisplayCoreTests/
├── LayoutCoreTests/
└── Runtime/         Standalone AppKit regression checks
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the architecture and runtime boundaries.

## Development

`project.yml` is the XcodeGen project definition. Keep application discovery, persisted layout state, deterministic geometry, and visual presentation as separate concerns. Avoid private frameworks and hard-coded display-specific layout behavior.

Engineering rules for coding agents and contributors are documented in [`AGENTS.md`](AGENTS.md).
