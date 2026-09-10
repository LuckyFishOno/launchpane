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

`AppCore` owns application identity and metadata, catalog discovery, local search, persisted launcher layout, reconciliation, and interaction state used by drag-and-drop operations.

Application discovery and user layout are intentionally separate. A temporary discovery failure must not silently rewrite the user's persisted arrangement.

### DisplayCore

`DisplayCore` converts `NSScreen` information into display context expressed in logical points. Screen geometry, safe areas, backing scale, and display changes are runtime inputs rather than assumptions encoded in the UI.

### LayoutCore

`LayoutCore` contains deterministic grid and folder layout solvers. Given display context and layout preferences, it produces geometry without depending on AppKit view state.

This design keeps the launcher adaptive across built-in displays, external monitors, scaled modes, and mixed backing scales.

### OpenLaunchpad Runtime

The application target owns AppKit windows, Core Animation presentation layers, search presentation, paging, icon rendering, pointer interaction, keyboard navigation, and accessibility controls.

Visual constants are centralized in typed style or metrics values. Interactive animations prefer stable layer ownership and presentation-state continuity to avoid duplicate rendering, afterimages, and discontinuities during rapid interaction.

## Paging

Paging is designed around direct manipulation:

- Trackpad movement maps directly to page displacement while the gesture is active.
- Adjacent page surfaces are staged near the current page to avoid first-frame hierarchy work.
- Release settling uses gesture velocity and a smooth deceleration profile.
- Long-session resource use is bounded so repeated paging does not continuously grow the active view or layer hierarchy.
- Reduce Motion disables nonessential motion while preserving navigation behavior.

## Search

Search normalization is case-insensitive and width/diacritic tolerant. Matching requires the complete normalized query to appear as one contiguous substring of the application display name.

The search field treats committed text and IME marked text as separate states. Marked text affects placeholder presentation immediately without prematurely committing it as a search query.

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
