# OpenLaunchpad

**A fast, native Launchpad replacement for macOS.**

For people who miss the classic full-screen app grid: OpenLaunchpad brings back fast app launching, instant search, folders, persistent drag-and-drop organization, and smooth paging — built natively with Swift, AppKit, and Core Animation.

<p align="center">
  <a href="https://github.com/LuckyFishOno/open-launchpad/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/LuckyFishOno/open-launchpad?display_name=tag&sort=semver"></a>
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-M1%2B-black?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

<p align="center">
  <img src="docs/assets/openlaunchpad-preview.png" width="1600" alt="OpenLaunchpad showing a full-screen grid of installed Mac apps" />
</p>

<p align="center">
  <a href="https://github.com/LuckyFishOno/open-launchpad/releases/latest/download/OpenLaunchpad.dmg"><strong>Download OpenLaunchpad</strong></a>
  ·
  <a href="https://github.com/LuckyFishOno/open-launchpad/releases/latest">Release notes</a>
  ·
  <a href="https://github.com/LuckyFishOno/open-launchpad/issues">Report an issue</a>
</p>

## See it in action

<p align="center">
  <img src="docs/assets/openlaunchpad-demo.gif" width="900" alt="OpenLaunchpad demo showing the app grid, folders, and paging" />
</p>

## Why OpenLaunchpad?

- **Feels at home on macOS.** Native AppKit and Core Animation UI with system application discovery.
- **Organize it your way.** Reorder apps, create folders, move items across pages, and keep the layout between launches.
- **Fast from keyboard, mouse, or trackpad.** Instant IME-aware search, keyboard navigation, and paging gestures.
- **Built for real displays.** Adaptive layout across Retina and non-Retina screens, mixed-scale multi-display setups, and different scaling modes.
- **Private by default.** No account, activation, analytics, telemetry, or mandatory network connection.
- **Accessible.** Keyboard navigation, accessibility semantics, right-to-left layout support, and Reduce Motion behavior.

## Requirements

- macOS 15 or later
- Apple silicon Mac (M1 or newer)

Intel Macs are not currently supported.

## Install

1. [Download the latest `OpenLaunchpad.dmg`](https://github.com/LuckyFishOno/open-launchpad/releases/latest/download/OpenLaunchpad.dmg).
2. Open the disk image.
3. Drag **OpenLaunchpad.app** into **Applications**.
4. Open OpenLaunchpad from **Applications**.
5. If macOS blocks the first launch, follow the one-time steps below.
6. Launch OpenLaunchpad again.
7. Optional: right-click **OpenLaunchpad** in the Dock → **Options** → **Keep in Dock** for one-click access.

### First launch on macOS

The current downloadable build is not notarized with an Apple Developer ID. Because of that, macOS may show an **“OpenLaunchpad” Not Opened** warning the first time you launch it.

1. Click **Done**.
2. Open **System Settings → Privacy & Security**.
3. Scroll to **Security**.
4. Click **Open Anyway** for OpenLaunchpad.
5. Authenticate if requested.
6. Click **Open**.

<img width="716" alt="Allowing OpenLaunchpad from macOS Privacy & Security settings" src="https://github.com/user-attachments/assets/d42ebbfc-6beb-4f20-82a5-d6173db66315" />

This approval is only required once for the downloaded build. If you prefer, you can also [build OpenLaunchpad from source](#build-from-source).

## What it supports

- Adaptive app grid and folder layout
- Installed application discovery
- Instant local search with IME-aware input
- Trackpad, mouse, and keyboard paging
- Persistent drag-and-drop reordering
- Folder creation and management
- Cross-page dragging with edge paging
- Folder-item reordering and multi-page folders
- Folder-to-root extraction
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

OpenLaunchpad is implemented in Swift 6 with AppKit and Core Animation. Display geometry flows through `DisplayContext` and `LayoutConstraintSolver`, while application discovery stays separate from the persisted user layout. Drag-and-reorder behavior is modeled as an explicit state machine with transaction and rollback semantics.

For implementation details, see [Architecture](docs/ARCHITECTURE.md) and [Paging performance](docs/PAGING_PERFORMANCE.md).

## Contributing

Bug reports and focused pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

If OpenLaunchpad is useful to you, **star the repository** — it helps more Mac users discover the project.

## License

OpenLaunchpad is available under the [MIT License](LICENSE).

OpenLaunchpad is an independent open-source project and is not affiliated with or endorsed by Apple Inc. macOS, Launchpad, and Apple are trademarks of Apple Inc.
