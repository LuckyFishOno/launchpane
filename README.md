# OpenLaunchpad

**A fast, native Launchpad replacement for macOS.**

OpenLaunchpad brings back the familiar full-screen app grid with instant search, folders, drag-and-drop organization, and smooth paging. It is built entirely with documented macOS APIs and works locally without accounts or telemetry.

<p align="center">
  <img src="docs/assets/openlaunchpad-preview.png" width="1600" alt="OpenLaunchpad showing a full-screen grid of installed Mac apps" />
</p>

<p align="center">
  <a href="https://github.com/LuckyFishOno/open-launchpad/releases/download/v1.2/OpenLaunchpad.dmg"><strong>Download OpenLaunchpad v1.2</strong></a>
  ·
  <a href="https://github.com/LuckyFishOno/open-launchpad/releases/latest">Release notes</a>
</p>

## Why OpenLaunchpad?

- **Feels at home on macOS.** A responsive AppKit and Core Animation interface with native app discovery.
- **Organize it your way.** Reorder apps, create folders, and drag items across pages; your layout persists between launches.
- **Fast from the keyboard or trackpad.** Search with IME-aware input, navigate by keyboard, and page with trackpad or mouse gestures.
- **Adapts to your display.** Supports mixed-scale multi-display setups, Retina and non-Retina screens, and different scaling modes.
- **Private by default.** No telemetry, account, activation, or mandatory network connection.
- **Accessible.** Supports keyboard navigation, accessibility semantics, right-to-left layouts, and Reduce Motion.

## Requirements

- macOS 15 or later
- Apple silicon Mac (M1 or newer)

Intel Macs are not currently supported.

## Install

1. [Download `OpenLaunchpad.dmg`](https://github.com/LuckyFishOno/open-launchpad/releases/download/v1.2/OpenLaunchpad.dmg).
2. Open the disk image and drag `OpenLaunchpad.app` into **Applications**.
3. Open OpenLaunchpad from **Applications**.
4. Optionally keep it in the Dock for one-click access.

### First launch on macOS

The current build is not notarized with an Apple Developer ID. If macOS says **“OpenLaunchpad” Not Opened**:

1. Click **Done**.
2. Open **System Settings → Privacy & Security**.
3. Scroll to **Security** and click **Open Anyway** for OpenLaunchpad.
4. Authenticate if requested, then click **Open**.

<img width="716" alt="Allowing OpenLaunchpad from macOS Privacy & Security settings" src="https://github.com/user-attachments/assets/d42ebbfc-6beb-4f20-82a5-d6173db66315" />

You only need to do this once for the downloaded build. You can also [build from source](#build-from-source).

## What it supports

- Adaptive app grid and folder layout
- Installed application discovery
- Instant local search with IME-aware input
- Trackpad, mouse, and keyboard paging
- Persistent drag-and-drop reordering
- Folder creation and management
- Cross-page dragging with edge paging
- Page-local placement and forward overflow
- Reset Launchpad action
- Multi-display and mixed-scale configurations
- Keyboard navigation, RTL layout, and Reduce Motion

## Build from source

You will need:

- Apple silicon Mac running macOS 15 or later
- Xcode 26 or later
- Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.42 or later only when regenerating the Xcode project

Clone and build:

```bash
git clone https://github.com/LuckyFishOno/open-launchpad.git
cd open-launchpad
xcodebuild \
  -project OpenLaunchpad.xcodeproj \
  -scheme OpenLaunchpad \
  -configuration Release \
  CONFIGURATION_BUILD_DIR="$PWD/Builds" \
  clean build
open Builds/OpenLaunchpad.app
```

## Layout data

OpenLaunchpad stores its layout locally at:

```text
~/Library/Application Support/OpenLaunchpad/LauncherLayout.json
```

The layout uses explicit pages and automatically migrates older saved layouts. Removing an app from one page does not pull apps backward from later pages. Dropping onto a full page pushes overflow forward and creates another page when needed.

## Architecture

The launcher runtime uses Swift 6, AppKit, and Core Animation. Display geometry flows through `DisplayContext` and `LayoutConstraintSolver`, while app discovery remains separate from the persisted user layout. Drag and reorder behavior is modeled as an explicit state machine with transaction and rollback semantics.

See [Architecture](docs/ARCHITECTURE.md) and [Paging performance](docs/PAGING_PERFORMANCE.md) for implementation details.

## Contributing

Bug reports and focused pull requests are welcome. Please include your macOS version, Mac model, display arrangement, and clear reproduction steps when reporting layout or interaction problems.

Before opening a pull request, run:

```bash
xcodebuild \
  -project OpenLaunchpad.xcodeproj \
  -scheme OpenLaunchpad \
  -destination 'platform=macOS' \
  test
```

If OpenLaunchpad is useful to you, consider starring the repository—it helps more Mac users find the project.
