# OpenLaunchpad Architecture

OpenLaunchpad is a native macOS launcher built with documented system APIs. The codebase separates application data, display geometry, deterministic layout, and presentation so that each area can evolve without coupling the entire launcher to a specific screen or interaction implementation.

## Module Boundaries

```text
AppCore ───────────────────────────────┐
                                       │
DisplayCore ──> LayoutCore ────────────┼──> OpenLaunchpad runtime
                                       │
Persisted layout state ────────────────┘
```

### AppCore

`AppCore` owns application identity and metadata, catalog discovery, local search, persisted launcher layout, reconciliation, drag-and-drop interaction state, and deterministic paging motion/input models.

Application discovery and user layout are intentionally separate. A temporary discovery failure must not silently rewrite the user's persisted arrangement.

### DisplayCore

`DisplayCore` converts `NSScreen` information into display context expressed in logical points. Screen geometry, safe areas, backing scale, and display changes are runtime inputs rather than assumptions encoded in the UI.

### LayoutCore

`LayoutCore` contains deterministic grid and folder layout solvers. Given display context and layout preferences, it produces geometry without depending on AppKit view state.

This design keeps the launcher adaptive across built-in displays, external monitors, scaled modes, and mixed backing scales.

### OpenLaunchpad Runtime

The Xcode application uses two processes. `OpenLaunchpad.app` is a short-lived Dock launcher that opens the embedded `OpenLaunchpadAgent.app`, or sends a toggle notification to an already-running agent. The accessory agent owns AppKit windows, Core Animation presentation layers, search presentation, paging, icon rendering, pointer interaction, keyboard navigation, and accessibility controls. Both processes use accessory activation; only the user-pinned launcher is intended to remain in the Dock. Embedding the agent under `Contents/Library/LoginItems` does not register it to launch at login.

SwiftPM exposes and tests the core libraries only. XcodeGen defines the two application targets and embeds the agent in the distributable launcher bundle.

Visual constants are centralized in typed style or metrics values. Interactive animations prefer stable layer ownership and presentation-state continuity to avoid duplicate rendering, afterimages, and discontinuities during rapid interaction.

### Desktop Background and Menu Region

`WallpaperLayout` maps the wallpaper onto the complete display in backing pixels using the desktop's scaling and clipping options. Menu-bar, Dock, and notch reservations constrain controls, not the wallpaper canvas. `DesktopWallpaperProvider` blurs and tones that canvas once, caching the plain and frosted images by file metadata, display geometry, and desktop options.

The main window and `MenuBarBackdropWindow` share the same frosted image. The latter exposes only the top rows in full-screen coordinates; it has no independent visual-effect material or tint. Its opacity animation follows the main window, with the plain desktop underneath to prevent menus showing through during a fade.

This is a visual replacement of the menu region while preserving the system Dock. AppKit's actual `hideMenuBar` presentation mode requires `hideDock`, so it cannot provide an interactive Dock. The main window remains below Dock and the top continuation closes when the app deactivates. No global menu/Dock settings are changed.

## Paging

Paging is designed around direct manipulation:

- Trackpad movement maps directly to page displacement while the gesture is active.
- Adjacent page surfaces are staged near the current page to avoid first-frame hierarchy work.
- Release settling uses gesture velocity and a smooth deceleration profile.
- Long-session resource use is bounded so repeated paging does not continuously grow the active view or layer hierarchy.
- Reduce Motion disables nonessential motion while preserving navigation behavior.

`PageMotionProfile` defines the 0.56-second discrete transition and distance-dependent, velocity-matched interactive settling. Duration is not stretched after calculating the curve. `PageSwipeInputGate` prevents a gesture begun during settling from interrupting it or entering midway after it completes. Phase-less wheel events still update the idle timer while animation is busy, preserving one page per burst.

Invalidating page content preserves ownership of old surfaces until rebuilding explicitly detaches them. This prevents staged adjacent-page trees from being orphaned after searching or reordering. See [paging measurements and regression checks](PAGING_PERFORMANCE.md).

## Search

Search normalization is case-insensitive and width/diacritic tolerant. Matching requires the complete normalized query to appear as one contiguous substring of the application display name.

The search field treats committed text and IME marked text as separate states. Marked text affects placeholder presentation immediately without prematurely committing it as a search query.

On a new opening, `presentFromLauncher()` resets search before ordering the window front. `resetForPresentation()` discards unfinished IME input, ends field-editor observation/editing, clears text, and cancels old focus-animation callbacks. The root restores grid keyboard focus, page zero, and the unfiltered application list. The empty magnifier/placeholder returns to its centered idle layout without an old-query flash during fade-in.

This reset also applies when reopening during dismissal, but not to live display changes or a show request while already presented. It does not change saved application order or folders. The [standalone runtime check](../Tests/Runtime/README.md) verifies these boundaries.

## Drag and Reordering

Same-page reordering keeps one page surface as the visual owner. The dragged application uses a temporary proxy while neighboring tiles move in place. This avoids duplicate page trees and prevents release-time afterimages.

Persistent changes are committed transactionally. Failure paths restore the pre-drag layout rather than leaving presentation state partially committed.

## Accessibility and Input

The visual grid is rendered with Core Animation, while native controls provide accessibility and hit-test semantics. Keyboard navigation, right-to-left layout, multi-display behavior, and Reduce Motion are architectural requirements rather than optional visual polish.

## Project Generation

`project.yml` is the XcodeGen source of truth for the Xcode project. Regenerate the project after changing targets, build settings, resources, or schemes:

```sh
xcodegen generate
```
