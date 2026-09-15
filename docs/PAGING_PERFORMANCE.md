# Paging motion and regression checks

## Changes (2026-09-11)

- Cache invalidation now retains ownership of old page surfaces until rebuilding
  detaches their layer trees. Clearing the dictionary first abandoned staged
  adjacent pages in the compositor tree after searches and layout changes.
- Wheel/keyboard transitions use a 0.56-second cubic instead of the previous
  front-loaded 0.48-second curve. Their normalized initial speed is reduced from
  8.125 to approximately 0.893 display widths per second.
- Interactive settling uses one cubic, sampled from the visible presentation
  position. Its initial derivative matches velocity toward the target, and its
  final derivative is zero. Duration is distance-dependent (0.18–0.56 seconds).
  There is no additional overall or tail time stretch after velocity matching.
- Tracking and settling are separate states. A gesture rejected during settling
  stays rejected until it ends; it cannot cancel the current animation or enter
  midway through its event stream. Phase-less wheel events still update the
  discrete gesture's idle clock while animation is running.
- Completed outgoing layers stay attached until adjacent-page staging retires
  them. Avoid detaching and immediately reattaching the same tree at every turn.
- Drag reflow/rollback remains 0.48 seconds. Desktop, Dock, search appearance,
  direct finger tracking, and Reduce Motion behavior are unchanged.

## Local before/after verification

The actual AppKit controller was compiled into an isolated runtime harness,
using a temporary layout store instead of the user's saved arrangement. Tests
ran on a 1710 × 1112-point Retina display with three application pages.

| Check | Previous implementation | Updated implementation |
| --- | --- | --- |
| Initial attached page trees / total layers | 2 / 289 | 2 / 289 |
| After 20 search/clear cycles | 42 / 4,249 | 2 / 289 |
| Orphan page trees after those cycles | 40 | 0 |
| New gesture during release animation | Cancels animation, resets page | Original animation completes |
| Remaining events from rejected gesture | Can restart dragging | Ignored through gesture end |

Eight alternating page turns took roughly 0.6–2.5 ms each to prepare on the main
thread in both builds. Main-thread display-link callback median and p95 were
approximately 16.67 and 16.69 ms in both builds. The updated trial had one
33.33-ms callback; the old trial's maximum was 22.68 ms. This is **not** a GPU or
WindowServer presentation trace and does not establish that all dropped frames
are eliminated. The reproducible regressions are layer accumulation and motion
interruption; the speed-curve discontinuity is also deterministically testable.

Runtime input checks (also passed on a 1920 × 1080-point display) cover a
32-event mixed-force wheel burst, a fresh light
notch after idle, reverse paging, horizontal rollback/cancellation, and paging
after rollback. Inputs are delivered directly to the view; no global event
injection or Accessibility permission is required.

## Repeatable checks

Run `swift test` for the core regression suite. `PageMotionProfileTests` verifies
both directions, different display widths and release speeds, short residual
travel, monotonic progress, duration limits, and endpoint velocity.
`PageSwipeInputGateTests` verifies busy/idle transitions and terminal/momentum
events. Existing gesture tests retain one-page-per-burst coverage.

For AppKit regression checks, run a Debug agent with
`LAUNCHPANE_PAGING_DIAGNOSTICS=1` in the agent's environment. `[PagingPerf]`
reports actual orphan page trees as well as tracked pages. Repeatedly search and
clear, change pages, and reorder applications. `orphanPageTrees` must remain zero;
only the current page and its immediate neighbors should stay staged when idle.
Also test quick successive swipes, an extended wheel burst, both display edges,
and Reduce Motion. Do not judge smoothness solely from animation duration or
main-thread frame callbacks.
