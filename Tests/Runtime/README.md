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
