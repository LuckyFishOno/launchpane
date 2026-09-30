# AppKit runtime regression checks

`SearchReopenCheck.swift` compiles alongside the real UI sources and drives their
methods directly. It checks partial search followed by outside-click dismissal,
normal/rapid reopening, incomplete IME composition, initial grid restoration,
centered placeholder, absence of an old caret/animation, and subsequent typing.
It also verifies that display preparation and showing an already-visible window
do not discard an active search.

This is separate from `swift test`: it requires a logged-in macOS graphical
session and temporarily brings a test launcher window forward. It uses a
temporary layout file and restores the previous foreground application when
finished. It does not inject global events or require Accessibility permission.

## Menu-bar opening animation

`MenuBarOpeningAnimationCheck.swift` constructs the production
`LaunchpadWindow` and `MenuBarBackdropWindow` and runs their real Core Animation
opening path. It verifies that the complete menu-bar continuation starts
transparent, covers and overlaps the selected display's top boundary, and uses
the launcher's exact measured opacity samples, key times, and duration in the
same transaction. It also guards against accidentally applying the launcher's
spatial scale to the top continuation. With Reduce Motion enabled, it verifies
that both surfaces resolve together without animations. It also checks the
synchronized 0.27-second dismissal and that the launcher is ordered out afterward.

Build Debug into `Builds`, then run:

```zsh
menu_check_dir=$(mktemp -d /private/tmp/launchpane-menu-check.XXXXXX)
runtime_sources=("${(@f)$(rg --files Sources/LaunchPane -g '*.swift' -g '!main.swift')}")
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" \
  -framework AppCore -framework DisplayCore -framework LayoutCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  "${runtime_sources[@]}" Tests/Runtime/MenuBarOpeningAnimationCheck.swift \
  -o "$menu_check_dir/menu-bar-opening-check"
"$menu_check_dir/menu-bar-opening-check"
```

Success ends with `MENU BAR OPENING: 26 assertions, 0 failures` when animation
is enabled. The check briefly displays the two test surfaces and then removes
them. It does not discover apps or read or write the saved launcher layout.

First build Debug into `Builds` using the root README. Then, from the repository
root, run these commands in **zsh** (with `rg` available):

```zsh
runtime_dir=$(mktemp -d /private/tmp/launchpane-search-check.XXXXXX)
runtime_sources=("${(@f)$(rg --files Sources/LaunchPane -g '*.swift' -g '!main.swift')}")
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" \
  -framework AppCore -framework DisplayCore -framework LayoutCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  "${runtime_sources[@]}" Tests/Runtime/SearchReopenCheck.swift \
  -o "$runtime_dir/search-check"

LAUNCHPANE_LAYOUT_PATH="$runtime_dir/layout.json" \
  "$runtime_dir/search-check"
```

Success ends with `SEARCH REOPEN: 0 failures` and exit status zero. Test artifacts
remain in the temporary directory referenced by `runtime_dir`; they are not part of the
app bundle or the user's saved launcher layout.

## Cross-page drag

`CrossPageDragCheck.swift` sends mouse events through `NSWindow.sendEvent`
and invokes cancellation on the pointer owner. Read-only reflection observes the actual
controller state; no alternate drag implementation or production test hook is
used. Fixtures include all discovered apps and explicit partial/full pages.
Assertions use the persisted snapshot after catalog reconciliation as the drag
baseline. Starting a drag must leave that snapshot unchanged; a committed drop
must advance its revision exactly once.

The check covers stationary traversal across multiple pages, returning to the
source page without detaching the pointer owner, release at the far edge,
release during an active transition, one persistence commit per drop, cancelling
the next dwell on release, Escape rollback without orphan transition layers,
new-page creation, and full-page overflow without backward gap filling.

It requires at least 16 installed apps. Like the search check, it temporarily
opens graphical windows but never injects global pointer input. Run from the
repository root after building Debug:

```zsh
drag_check_dir=$(mktemp -d /private/tmp/launchpane-drag-check.XXXXXX)
runtime_sources=("${(@f)$(rg --files Sources/LaunchPane -g '*.swift' -g '!main.swift')}")
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" \
  -framework AppCore -framework DisplayCore -framework LayoutCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  "${runtime_sources[@]}" Tests/Runtime/CrossPageDragCheck.swift \
  -o "$drag_check_dir/cross-page-check"
LAUNCHPANE_LAYOUT_PATH="$drag_check_dir/layout.json" \
  "$drag_check_dir/cross-page-check"
```

Success ends with `CROSS PAGE DRAG: 0 failures`. This verifies event ordering
and persistence, not physical trackpad timing or GPU frame pacing.

## Pointer ownership during folder reorder

`PointerOwnershipCheck.swift` sends events through `NSWindow.sendEvent`, which
exercises AppKit dispatch instead of calling the source button directly. It checks
hidden/disabled source views, continued dragging, release outside the window,
exactly one release, and cancellation on detachment. Folder fixtures cover local
reorder, cross-page release, release during paging, persisted order, live hit
targets, and immediately starting another drag without Escape.
Commit counting starts after catalog reconciliation, using the persisted document
immediately before dragging. The check also verifies that previews leave that
document unchanged before mouse-up.

It also verifies that landing preserves the existing folder panel and icon
presentations, and that reused buttons drag from their newly committed slots.

Compile/run using the cross-page command above, substituting
`PointerOwnershipCheck.swift` and `pointer-ownership-check`. It requires 40
installed apps and an isolated layout path under `/private/tmp/`. Success ends
with `POINTER OWNERSHIP: 0 failures`.

## Page projection and unresolved references

`ResolvedPageCheck.swift` is a non-GUI companion check for explicit page ranges,
empty pages, packed search results, and mapping visible insertion slots back to
persisted indices when some application references cannot be resolved.

```zsh
projection_check_dir=$(mktemp -d /private/tmp/launchpane-projection-check.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" -framework AppCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  Sources/LaunchPane/ResolvedLaunchpadItem.swift \
  Tests/Runtime/ResolvedPageCheck.swift \
  -o "$projection_check_dir/resolved-page-check"
"$projection_check_dir/resolved-page-check"
```

Success ends with `RESOLVED PAGES: 42 assertions passed`.

## Reset Launchpad

`ResetLaunchpadCheck.swift` starts with a folder and explicit custom pages in an
isolated layout file. It invokes the real search-field menu callback, verifies
that cancelling the confirmation leaves the exact document unchanged, then
confirms reset and checks the canonical default layout, replacement of custom
folders by Utilities, and a single revision increment.

Compile it using the same command as `CrossPageDragCheck.swift`, replacing that
source filename and output name with `ResetLaunchpadCheck.swift` and
`reset-launchpad-check`. Success ends with `RESET LAUNCHPAD: 0 failures`.

## Wallpaper and memory

These checks work with the Release frameworks built into `Builds`. They never
activate the launcher or display a window. `AgentMemoryCheck` creates a hidden
window and discovers applications using a fresh temporary layout, then reports
physical footprint after warming. This is an offscreen comparison, not a measure
of visible compositor surfaces. Both other checks avoid discovery and persistence.

From the repository root in **zsh**:

```zsh
memory_check_dir=$(mktemp -d /private/tmp/launchpane-memory-checks.XXXXXX)
runtime_sources=("${(@f)$(rg --files Sources/LaunchPane -g '*.swift' -g '!main.swift')}")
for check_name in WallpaperRasterCheck WallpaperCanvasCheck IconCacheScaleCheck AgentMemoryCheck; do
  swiftc -O -swift-version 6 -parse-as-library \
    -F "$PWD/Builds" \
    -framework AppCore -framework DisplayCore -framework LayoutCore \
    -Xlinker -rpath -Xlinker "$PWD/Builds" \
    "${runtime_sources[@]}" "Tests/Runtime/$check_name.swift" \
    -o "$memory_check_dir/$check_name" || break
  "$memory_check_dir/$check_name" || break
done
```

Raster verification expects 298 passing assertions; icon scale-cache verification
expects 16. The latter uses synthetic 64-bit P3 images and checks original image
identity, retained dimensions/bit depth, scale upgrades, reversed completion
order, and invalidation without touching real application icons. Canvas assertion count
depends on connected displays and wallpaper availability; failures must be zero.
It also checks relayout while the wallpaper's inverse transition scale is active.
See [memory findings and manual acceptance](../../docs/MEMORY.md).

Run `"$memory_check_dir/AgentMemoryCheck" --cycle-displays` to exercise two passes
through all connected display sizes and backing scales with the window hidden.
Each step waits for the real icon-prewarm task, then records physical footprint.

For the actual visible 4K case, run `zsh Tests/Runtime/SampleAgentMemory.zsh`,
then open Launchpad on that display within eight seconds and leave it visible.
The report is saved in `Builds`; the script neither launches nor kills the app.
Capturing after returning to Terminal would instead measure the hidden state.

## Opacity curve reversal

`OpacityCurveCheck.swift` verifies the pure curve slicing used by window opening,
closing, and rapid reversal. It covers ascending/descending interpolation, empty
and single-sample curves, normalized key times, and every 1% opacity boundary.
It does not create windows or read the user's layout.

```zsh
curve_check_dir=$(mktemp -d /private/tmp/launchpane-curve-check.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  Sources/LaunchPane/OpacityCurveSegment.swift Tests/Runtime/OpacityCurveCheck.swift \
  -o "$curve_check_dir/check"
"$curve_check_dir/check"
```

Success ends with `OPACITY CURVE: 1018 assertions passed`.

## Folder merge and spring opening

`FolderMergeCheck.swift` drives real tile events. `FolderMergeScenarios.swift`
contains the eight approach directions, merge dwell, spring opening, cancellation,
reorder, offset-grab, and existing-folder scenarios. After spring opening, it also
checks folder-title Escape cancellation, Enter persistence, whitespace trimming,
duplicate end-edit notifications, and reopening the editor. Compile both test files:

```zsh
runtime_sources=("${(@f)$(rg --files Sources/LaunchPane -g '*.swift' -g '!main.swift')}")
folder_check_dir=$(mktemp -d /private/tmp/launchpane-folder-check.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" -framework AppCore -framework DisplayCore -framework LayoutCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  "${runtime_sources[@]}" Tests/Runtime/FolderMergeCheck.swift Tests/Runtime/FolderMergeScenarios.swift \
  -o "$folder_check_dir/check"
LAUNCHPANE_LAYOUT_PATH="$folder_check_dir/layout.json" "$folder_check_dir/check"
```

This requires a logged-in graphical session and at least three complete app rows.
Success ends with `FOLDER MERGE: 0 failures`.

## Root page swipe lifecycle

`PageSwipeLifecycleCheck.swift` exercises the production root-view swipe methods
without opening a window or discovering applications. It checks frame-coalesced
presentation, cancellation generation invalidation, original-page restoration,
and final page/layer ownership in both directions at three logical widths.
The completion case starts at the destination so it has no remaining animation
and is independent of refresh rate and Reduce Motion. Timed gestures and pointer
ownership remain covered separately by the graphical runtime checks.

```zsh
runtime_sources=("${(@f)$(rg --files Sources/LaunchPane -g '*.swift' -g '!main.swift')}")
swipe_check_dir=$(mktemp -d /private/tmp/launchpane-swipe-check.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" \
  -framework AppCore -framework DisplayCore -framework LayoutCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  "${runtime_sources[@]}" Tests/Runtime/PageSwipeLifecycleCheck.swift \
  -o "$swipe_check_dir/swipe-check"
"$swipe_check_dir/swipe-check"
```

Success ends with `PAGE SWIPE LIFECYCLE: 72 assertions passed`.

## Icon prewarm planning and cancellation

`IconPrewarmCheck.swift` checks first-page folder priority, full child coverage,
identity deduplication, catalog fallback, and independent cancellation of visible,
presentation-wide, and idle pinned work. It does not open windows or decode icons.

```zsh
icon_check_dir=$(mktemp -d /private/tmp/launchpane-icon-prewarm.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" -framework AppCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  Sources/LaunchPane/ResolvedLaunchpadItem.swift \
  Sources/LaunchPane/IconWarmPlan.swift Sources/LaunchPane/IconPrewarmTasks.swift \
  Tests/Runtime/IconPrewarmCheck.swift -o "$icon_check_dir/icon-prewarm-check"
"$icon_check_dir/icon-prewarm-check"
```

Success ends with `ICON PREWARM: 12 assertions passed`. `IconCacheScaleCheck.swift`
separately verifies bitmap cache behavior; the graphical search and folder checks
exercise integration with the production view lifecycle.

## Folder presentation ownership

`FolderPresentationCheck.swift` constructs the production visual-resource owner
without opening a window or discovering apps. It verifies animation invalidation,
icon-task cancellation, layer/editor cleanup, safe repeated cleanup, and preserving
the exact button that still owns a drag while other hit targets are removed.

```zsh
runtime_sources=("${(@f)$(rg --files Sources/LaunchPane -g '*.swift' -g '!main.swift')}")
folder_owner_dir=$(mktemp -d /private/tmp/launchpane-folder-owner.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" \
  -framework AppCore -framework DisplayCore -framework LayoutCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  "${runtime_sources[@]}" Tests/Runtime/FolderPresentationCheck.swift \
  -o "$folder_owner_dir/folder-owner-check"
"$folder_owner_dir/folder-owner-check"
```

Success ends with `FOLDER PRESENTATION: 15 assertions passed`. Run
`PointerOwnershipCheck` and `FolderMergeCheck` for the real window and drag paths.

The folder-ownership extraction exposed eight existing `FolderMergeCheck`
failures in upper-right and lower-left approaches, also reproduced on `565d39f`.
Tracing showed the reorder dwell expired before a long diagonal path reached the
merge zone, moving the target away. The runtime now refreshes insertion dwell
only while the dragged icon moves toward the acquisition zone inside that
visible target's cell. Stationary samples, moving away, and paths past the icon
still allow reorder. Geometry tests cover multiple icon sizes and all directions;
the original graphical assertions remain in place.

## Folder paging ownership

`FolderPagingCheck.swift` exercises the production folder paging owner without
opening windows or discovering applications. It verifies explicit selection
updates, drag page handoffs that preserve selection, page clamping, cache
replacement, layer release, and cancellation in both directions at three panel
widths. Cancellation must invalidate old callbacks without changing the selected
page/item and must remain safe when repeated.

```zsh
runtime_sources=("${(@f)$(rg --files Sources/LaunchPane -g '*.swift' -g '!main.swift')}")
folder_paging_dir=$(mktemp -d /private/tmp/launchpane-folder-paging.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" \
  -framework AppCore -framework DisplayCore -framework LayoutCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  "${runtime_sources[@]}" Tests/Runtime/FolderPagingCheck.swift \
  -o "$folder_paging_dir/folder-paging-check"
"$folder_paging_dir/folder-paging-check"
```

Success ends with `FOLDER PAGING: 44 assertions passed`. The graphical
`PointerOwnershipCheck` covers preserving the active drag button through folder
page changes and rollback; `FolderMergeCheck` covers opening, merging, and editing.

## Drag interaction ownership

`DragInteractionCheck.swift` exercises the production drag coordinator, including
phase transitions, invalid commits, rollback, dismissal shielding, delayed pointer
retirement, and repeatable idle cleanup. It creates AppKit views without opening a
window and waits for the coordinator's actual deferred retirement task.

```zsh
runtime_sources=("${(@f)$(rg --files Sources/LaunchPane -g '*.swift' -g '!main.swift')}")
drag_owner_dir=$(mktemp -d /private/tmp/launchpane-drag-owner.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" \
  -framework AppCore -framework DisplayCore -framework LayoutCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  "${runtime_sources[@]}" Tests/Runtime/DragInteractionCheck.swift \
  -o "$drag_owner_dir/drag-owner-check"
"$drag_owner_dir/drag-owner-check"
```

Success ends with `DRAG INTERACTION: 16 assertions passed`. The real input paths
are covered by `PointerOwnershipCheck`, `CrossPageDragCheck`, and `FolderMergeCheck`.

## Drag target resolution

`DragTargetResolverCheck.swift` tests the production geometry resolver without
AppKit views or timers: visible folder acquisition, quick-drop insertion fallback,
approach suppression, diagonal motion versus a stationary gutter hold, absent
candidate rejection, and cross-page insertion in LTR and RTL layouts.

```zsh
target_check_dir=$(mktemp -d /private/tmp/launchpane-target-check.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" \
  -framework AppCore -framework DisplayCore -framework LayoutCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  Sources/LaunchPane/ResolvedLaunchpadItem.swift Sources/LaunchPane/DragTargetResolver.swift \
  Tests/Runtime/DragTargetResolverCheck.swift -o "$target_check_dir/target-check"
"$target_check_dir/target-check"
```

Success ends with `DRAG TARGET RESOLVER: 16 assertions passed`. Run
`FolderMergeCheck` and `CrossPageDragCheck` for integration with the actual input,
presentation geometry, preview, and persistence paths.
