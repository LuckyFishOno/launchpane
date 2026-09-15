# LaunchPane Engineering Rules

- Use Swift 6 and documented macOS APIs in production targets.
- Build the launcher runtime with AppKit and Core Animation. Reserve SwiftUI for settings and onboarding.
- Treat display geometry as runtime input. Do not branch on named resolutions.
- Route grid, tile, folder, and paging geometry through `DisplayContext` and `LayoutConstraintSolver`.
- Keep visual constants in typed token or metrics values rather than scattering literals through views.
- Keep app discovery separate from persisted user layout.
- Model drag and reorder interaction as an explicit state machine with transaction and rollback semantics.
- Do not make private frameworks, Apple-only entitlements, Accessibility permission, or gesture capture prerequisites for core use.
- Preserve keyboard navigation, accessibility semantics, RTL layout, Reduce Motion, and mixed-scale multi-display support as architectural requirements.
- Keep telemetry disabled by default. Do not add accounts, activation, or mandatory network access.
- Add deterministic unit tests before visual tuning, especially for layout behavior and persistence migrations.
