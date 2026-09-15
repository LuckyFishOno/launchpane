# Contributing to LaunchPane

Thanks for helping improve LaunchPane.

## Before you start

LaunchPane is a native macOS application written in Swift 6 with AppKit and Core Animation. Changes should preserve the project's native architecture and documented-system-API approach.

For bugs involving layout, dragging, paging, folders, or multiple displays, please include:

- macOS version
- Mac model and Apple silicon generation
- Built-in or external display model
- Display resolution and scaling mode
- Whether multiple displays were connected
- Clear reproduction steps
- A screen recording when the issue is visual or timing-sensitive

## Build

Requirements:

- macOS 15 or later
- Apple silicon Mac
- Xcode 26 or later
- Swift 6
- XcodeGen 2.42 or later only when regenerating the Xcode project

Build with:

```bash
xcodebuild \
  -project LaunchPane.xcodeproj \
  -scheme LaunchPane \
  -configuration Debug \
  build
```

## Test

Before opening a pull request, run:

```bash
xcodebuild \
  -project LaunchPane.xcodeproj \
  -scheme LaunchPane \
  -destination 'platform=macOS' \
  test
```

Please keep changes focused, explain user-visible behavior changes, and include regression coverage when fixing layout or state-machine bugs.

## Pull requests

A good pull request includes:

1. The problem being solved.
2. The approach taken.
3. Any behavior or compatibility tradeoffs.
4. Test coverage or manual verification performed.
5. Before/after screenshots or recordings for visual changes.

Small, focused pull requests are easier to review and merge.
