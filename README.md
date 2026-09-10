# OpenLaunchpad

OpenLaunchpad is a native macOS application launcher built with Swift 6, AppKit, Core Animation, and documented system APIs.

Version 1.0 focuses on a fast, responsive launcher experience with adaptive layout, native application discovery, local search, interactive paging, persistent reordering, and folders.

## Features

- Native AppKit and Core Animation runtime.
- Adaptive grid layout based on logical display geometry rather than hard-coded resolutions.
- Multi-display and mixed-scale support, including Retina and non-Retina displays.
- Installed-application discovery using public filesystem and bundle metadata APIs.
- Case-insensitive contiguous-substring search by application display name.
- IME-aware search presentation for marked text such as Zhuyin, Pinyin, and Japanese input.
- Interactive trackpad paging with direct finger tracking and smooth velocity-aware settling.
- Persistent drag-and-drop reordering and folder creation.
- Keyboard navigation and native accessibility hit targets.
- Right-to-left layout support.
- Respect for the macOS Reduce Motion setting.
- No telemetry, account, or mandatory network connection.

## Requirements

- macOS 15 or later
- Xcode 26 or later
- XcodeGen 2.42 or later

## Build and Run

OpenLaunchpad is a native macOS application and should be built with Xcode.

### Requirements

- macOS 15 or later
- Xcode
- Swift 6

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
rm -rf Builds

xcodebuild \
  -project OpenLaunchpad.xcodeproj \
  -scheme OpenLaunchpad \
  -configuration Debug \
  CONFIGURATION_BUILD_DIR="$PWD/Builds" \
  clean build
```

### Release Build

To create an optimized Release build in the same project-local output directory:

```bash
rm -rf Builds

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

## Project Structure

```text
Sources/
├── AppCore/          Application discovery, search, layout persistence, and drag state
├── DisplayCore/      Display geometry and screen resolution handling
├── LayoutCore/       Adaptive grid and folder layout solvers
└── OpenLaunchpad/    AppKit/Core Animation application runtime

Tests/
├── AppCoreTests/
├── DisplayCoreTests/
└── LayoutCoreTests/
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the architecture and runtime boundaries.

## Development

`project.yml` is the XcodeGen project definition. Keep application discovery, persisted layout state, deterministic geometry, and visual presentation as separate concerns. Avoid private frameworks and hard-coded display-specific layout behavior.

Engineering rules for coding agents and contributors are documented in [`AGENTS.md`](AGENTS.md).
