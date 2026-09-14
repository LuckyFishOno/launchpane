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

First build Debug into `Builds` using the root README. Then, from the repository
root, run these commands in **zsh** (with `rg` available):

```zsh
runtime_dir=$(mktemp -d /private/tmp/openlaunchpad-search-check.XXXXXX)
runtime_sources=("${(@f)$(rg --files Sources/OpenLaunchpad -g '*.swift' -g '!main.swift')}")
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" \
  -framework AppCore -framework DisplayCore -framework LayoutCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  "${runtime_sources[@]}" Tests/Runtime/SearchReopenCheck.swift \
  -o "$runtime_dir/search-check"

OPENLAUNCHPAD_LAYOUT_PATH="$runtime_dir/layout.json" \
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

The check covers stationary traversal across multiple pages, returning to the
source page without detaching the pointer owner, release at the far edge,
release during an active transition, one persistence commit per drop, cancelling
the next dwell on release, Escape rollback without orphan transition layers,
new-page creation, and full-page overflow without backward gap filling.

It requires at least 16 installed apps. Like the search check, it temporarily
opens graphical windows but never injects global pointer input. Run from the
repository root after building Debug:

```zsh
drag_check_dir=$(mktemp -d /private/tmp/openlaunchpad-drag-check.XXXXXX)
runtime_sources=("${(@f)$(rg --files Sources/OpenLaunchpad -g '*.swift' -g '!main.swift')}")
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" \
  -framework AppCore -framework DisplayCore -framework LayoutCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  "${runtime_sources[@]}" Tests/Runtime/CrossPageDragCheck.swift \
  -o "$drag_check_dir/cross-page-check"
OPENLAUNCHPAD_LAYOUT_PATH="$drag_check_dir/layout.json" \
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
projection_check_dir=$(mktemp -d /private/tmp/openlaunchpad-projection-check.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  -F "$PWD/Builds" -framework AppCore \
  -Xlinker -rpath -Xlinker "$PWD/Builds" \
  Sources/OpenLaunchpad/ResolvedLaunchpadItem.swift \
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
memory_check_dir=$(mktemp -d /private/tmp/openlaunchpad-memory-checks.XXXXXX)
runtime_sources=("${(@f)$(rg --files Sources/OpenLaunchpad -g '*.swift' -g '!main.swift')}")
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
