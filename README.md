# LaunchPane

**Bring back the classic full-screen app launcher on macOS.**

LaunchPane is a fast, native, open-source Launchpad replacement built with **Swift 6**, **AppKit**, and **Core Animation**. It gives you a full-screen app grid, instant local search, folders, persistent drag-and-drop organization, and smooth paging without accounts, telemetry, or mandatory network access.

<p align="center">
  <a href="https://github.com/LuckyFishOno/launchpane/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/LuckyFishOno/launchpane?display_name=tag&sort=semver"></a>
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-M1%2B-black?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

<p align="center">
  <img src="docs/assets/launchpane-preview.png" width="1600" alt="LaunchPane showing a full-screen grid of installed Mac apps" />
</p>

<p align="center">
  <a href="https://github.com/LuckyFishOno/launchpane/releases/latest/download/LaunchPane.dmg"><strong>Download LaunchPane</strong></a>
  ·
  <a href="https://github.com/LuckyFishOno/launchpane/releases/latest">Release notes</a>
  ·
  <a href="#build-from-source">Build from source</a>
  ·
  <a href="https://github.com/LuckyFishOno/launchpane/issues">Report an issue</a>
</p>

<p align="center">
  macOS 15+ · Apple silicon · MIT licensed · Local-first
</p>

## Why LaunchPane?

LaunchPane is designed for people who want the familiar full-screen macOS app-grid experience with predictable organization and native interactions.

| | |
| --- | --- |
| **Native macOS UI** | Built with AppKit and Core Animation using documented system APIs. |
| **Persistent organization** | Reorder apps, create folders, move items across pages, and keep the layout between launches. |
| **Fast navigation** | Search locally, page with a trackpad or mouse, and navigate from the keyboard. |
| **Adaptive layout** | Handles Retina and non-Retina displays, mixed-scale multi-display setups, and different scaling modes. |
| **Private by default** | No account, activation, analytics, telemetry, or mandatory network connection. |
| **Accessible** | Keyboard navigation, accessibility semantics, right-to-left layout support, and Reduce Motion behavior. |

## Features

- Full-screen adaptive app grid
- Installed application discovery
- Instant local search with IME-aware input
- Folder creation and management
- Persistent drag-and-drop reordering
- Cross-page dragging with edge paging
- Folder-item reordering and multi-page folders
- Folder-to-root extraction
- Trackpad, mouse, and keyboard paging
- Page-local placement with forward overflow
- Multi-display and mixed-scale support
- Keyboard navigation, RTL layout, and Reduce Motion support
- Reset Launchpad action

## Requirements

- **macOS 15 or later**
- **Apple silicon Mac** (M1 or newer)

Intel Macs are not currently supported.

## Install

1. [Download the latest `LaunchPane.dmg`](https://github.com/LuckyFishOno/launchpane/releases/latest/download/LaunchPane.dmg).
2. Open the disk image.
3. Drag **LaunchPane.app** into **Applications**.
4. Open LaunchPane from **Applications**.
5. Optionally, right-click **LaunchPane** in the Dock → **Options** → **Keep in Dock** for one-click access.

### First launch on macOS

> [!NOTE]
> The current downloadable build is not notarized with an Apple Developer ID. macOS may therefore block the first launch until you explicitly approve it. This is a one-time step for the downloaded build.

If macOS shows an **“LaunchPane” Not Opened** warning:

1. Click **Done**.
2. Open **System Settings → Privacy & Security**.
3. Scroll to **Security**.
4. Click **Open Anyway** for LaunchPane.
5. Authenticate if requested.
6. Click **Open**.

<img width="716" alt="Allowing LaunchPane from macOS Privacy & Security settings" src="https://github.com/user-attachments/assets/d42ebbfc-6beb-4f20-82a5-d6173db66315" />

If you prefer not to use the downloadable build, you can [build LaunchPane from source](#build-from-source).

## Build from source

### Prerequisites

- Apple silicon Mac running macOS 15 or later
- Xcode 26 or later
- Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.42 or later only if you want to regenerate the Xcode project

### Build

```bash
git clone https://github.com/LuckyFishOno/launchpane.git
cd launchpane

xcodebuild \
  -project LaunchPane.xcodeproj \
  -scheme LaunchPane \
  -configuration Release \
  CONFIGURATION_BUILD_DIR="$PWD/Builds" \
  clean build

open Builds/LaunchPane.app
```

### Run the test suite

```bash
swift test
```

## Local data and privacy

LaunchPane stores its layout locally at:

```text
~/Library/Application Support/LaunchPane/LauncherLayout.json
```

The layout uses explicit pages. Removing an app from one page does not pull apps backward from later pages, while dropping onto a full page pushes overflow forward and creates another page when needed.

LaunchPane does not require an account and does not send analytics or telemetry.

## Architecture

LaunchPane separates application discovery, display geometry, layout behavior, and presentation so each part can be tested independently.

```mermaid
flowchart LR
    Apps[Installed applications] --> AppCore[AppCore]
    Display[macOS displays] --> DisplayCore[DisplayCore]
    LayoutFile[Local layout JSON] <--> AppCore
    DisplayCore --> LayoutCore[LayoutCore]
    AppCore --> Agent[LaunchPaneAgent]
    LayoutCore --> Agent
    Launcher[LaunchPane.app] --> Agent
    Agent --> UI[AppKit + Core Animation UI]
```

The launcher process stays intentionally small, while the persistent UI lives in `LaunchPaneAgent`. Display geometry flows through `DisplayContext` and `LayoutConstraintSolver`, and drag-and-reorder behavior is modeled as an explicit state machine with transaction and rollback semantics.

For implementation details, see [Architecture](docs/ARCHITECTURE.md) and [Paging performance](docs/PAGING_PERFORMANCE.md).

## Contributing

Bug reports and focused pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

Useful feedback includes:

- interaction or animation issues
- unusual display or scaling configurations
- keyboard or accessibility behavior
- app-discovery edge cases
- reproducible drag-and-drop problems

If LaunchPane is useful to you, **star the repository** — it helps more Mac users discover the project.

## License

LaunchPane is available under the [MIT License](LICENSE).

LaunchPane is an independent open-source project and is not affiliated with or endorsed by Apple Inc. macOS, Launchpad, and Apple are trademarks of Apple Inc.
