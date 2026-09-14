# OpenLaunchpad

OpenLaunchpad is a native macOS application launcher built with Swift 6, AppKit, Core Animation, and documented system APIs.

Version 1.0 focuses on a fast, responsive launcher experience with adaptive layout, native application discovery, search, paging, persistent reordering, and folders.

## Preview

<!-- Replace the line below with your actual screenshot. -->
<!-- Example: <img width="1600" alt="OpenLaunchpad" src="YOUR_IMAGE_URL" /> -->

> Add an actual OpenLaunchpad screenshot here.

## Download

[Download OpenLaunchpad v1.2 for Mac](https://github.com/LuckyFishOno/open-launchpad/releases/download/v1.2/OpenLaunchpad.dmg)

OpenLaunchpad supports Apple silicon Macs with an M1 chip or newer. Intel Macs are not supported.

## Installation

1. Download `OpenLaunchpad.dmg`.
2. Open the disk image.
3. Drag `OpenLaunchpad.app` into the `Applications` folder.
4. Launch OpenLaunchpad from `Applications`.

### First Launch

OpenLaunchpad is currently distributed without Apple Developer ID notarization.

If macOS shows an **“OpenLaunchpad” Not Opened** warning:

1. Click **Done**.
2. Open **System Settings → Privacy & Security**.
3. Scroll to **Security**.
4. Click **Open Anyway** for OpenLaunchpad.
<img width="716" height="425" alt="setting" src="https://github.com/user-attachments/assets/d42ebbfc-6beb-4f20-82a5-d6173db66315" />

5. Authenticate if requested.
6. Click **Open**.
7. Drag OpenLaunchpad.app from the Applications folder to the Dock for quick access.

After this is allowed once, macOS will remember the choice.

## System Requirements

- macOS 15 or later
- Apple silicon Mac with an M1 chip or newer
- Intel Macs are not supported

## Features

- Native AppKit and Core Animation interface
- Adaptive grid layout for different display sizes and scaling modes
- Multi-display, Retina, and non-Retina support
- Native installed-application discovery
- Fast local application search with IME-aware input
- Interactive trackpad paging and smooth wheel/keyboard paging
- Persistent drag-and-drop reordering
- Folder creation and management
- Multi-page dragging with edge paging
- Page-local app placement and forward overflow
- Reset Launchpad action
- Keyboard navigation and accessibility support
- Right-to-left layout support
- Respects macOS Reduce Motion
- No telemetry, account, or mandatory network connection

## Layout Data

OpenLaunchpad stores its layout at:

```text
~/Library/Application Support/OpenLaunchpad/LauncherLayout.json
```

The current layout format uses explicit pages and supports automatic migration from older layouts.

Moving an app out of a page does not pull apps backward from later pages. Dropping into a full page pushes overflow forward and creates another page when necessary.

## Build

### Requirements

- Apple silicon Mac
- macOS 15 or later
- Xcode 26 or later
- Swift 6
- XcodeGen 2.42 or later when regenerating the Xcode project

### Release Build

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

The built app is available at:

```text
Builds/OpenLaunchpad.app
```
