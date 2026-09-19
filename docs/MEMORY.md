# Agent memory

The agent retains the catalog, saved layout, search state, interaction machinery,
original app icons, and preloaded pages. No icon resizing, bit-depth conversion,
folder preload reduction, animation removal, or hidden-window teardown is used.

The background and cache changes reduce image storage:

- The main and menu wallpaper layers share the same cached material image directly.
- The intentionally frosted material is limited to a 1280-pixel long edge.
- Placement is resolved in native coordinates before downsampling; blur radius scales with the material raster.
- Only the menu-bar rows of the plain desktop are rendered and cached.
- The menu clips the full material layer in display coordinates, preserving interpolation at the seam.
- Eager Core Image output and scratch-cache cleanup release temporary rendering resources.
- The icon cache keeps one original representation per app, reusing higher-resolution images for smaller requests.

At 3840 × 2160 pixels, a single RGBA8 full-screen raster holds about 31.6 MiB;
the 1280 × 720 frosted material holds about 3.5 MiB. This background resolution
tradeoff is explicitly user-approved. App icon decoding, dimensions, bit depth,
and color space remain intact. Larger icon requests still decode the original
larger representation; late smaller loads cannot downgrade it. Cached backgrounds
and preloaded icons remain available for reopening and display switching.

## Verification

`swift test` passes 170 core tests, including bounded material geometry, portrait
displays, blur scaling, and invalid inputs. `WallpaperRasterCheck.swift` passes
298 assertions over 1×, 1.25×, 2×, and 3× scales, all wallpaper scaling modes,
and clipping on/off. It checks unchanged small-raster output, exact native plain
menu rows, and the bounded large material dimensions and byte cost.

`WallpaperCanvasCheck.swift` checks shared image ownership, redraw retention,
accessibility, display geometry, and inverse-transform stability during relayout.
It passes 426 assertions on the three connected displays, creates no windows,
and performs no application discovery or layout writes. `IconCacheScaleCheck`
passes 16 deterministic assertions using 64-bit P3 images, including asynchronous
completion order and explicit invalidation. Release compilation passes.

`AgentMemoryCheck.swift` creates a hidden window and uses a fresh temporary layout.
Its `--cycle-displays` mode waits for real icon-prewarm completion while moving
the hidden window twice through 1710 × 1112 @2×, 3840 × 2160 @1×, and
1920 × 1080 @1× displays, with 100 discovered applications. The reference uses
the previous native-material renderer and separate per-size icon cache:

| Offscreen display cycling | Previous native material / separate icon sizes | Bounded material / shared original icons |
| --- | ---: | ---: |
| Largest sampled first-pass footprint | 613.4 MiB | 285.5 MiB |
| Second pass, settled range | 430.9–431.3 MiB | 213.3–213.6 MiB |

These are sampled offscreen values, not process peaks or visible-state results.
The prior native-material agent actually recorded 439.1 MiB current / 640.1 MiB
peak after the user reported approximately 600 MB while visibly open on 4K.
The original one-display offscreen result of 156.2 MiB therefore did not establish
acceptable visible or multi-display behavior. The new version still does **not**
establish a 100/200 MB limit; even its settled offscreen result exceeds 200 MB.
Final footprint depends on display geometry, the icon
working set, connected-display caches, and rendering state. Reproduce the same
display and application set when comparing builds.

## Manual acceptance

Build Release using the commands in the root README. The required acceptance
case is **Launchpad open and stationary on the 4K display**, not merely hidden.
Also check memory after closing and leaving the agent idle. Repeat
search/clear, folder open/close, paging, and several rapid close/reopen cycles;
memory should settle rather than grow with every repetition.

Check original icon sharpness, the menu-bar seam, Dock access, opening/closing
animations, immediate folder opening, keyboard navigation, drag/reorder, and
Reduce Motion. Move between displays with different backing scales and change
wallpaper placement to verify refresh and cached reopening.

For a delayed command-line measurement while the launcher stays visible:

```zsh
zsh Tests/Runtime/SampleAgentMemory.zsh
```

LaunchPane on 4K within eight seconds and leave it open. The read-only report
is saved in `Builds`; the script does not launch, kill, or replace the agent.
Use **Physical footprint**, including compressed memory, rather than only RSS.
The offline runtime checks are documented in `Tests/Runtime/README.md`.
