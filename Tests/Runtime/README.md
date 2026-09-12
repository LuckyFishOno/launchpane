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

`CrossPageDragCheck.swift` drives `AppTileButton.mouseDown`, `mouseDragged`,
`mouseUp`, and cancellation directly. Read-only reflection observes the actual
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
