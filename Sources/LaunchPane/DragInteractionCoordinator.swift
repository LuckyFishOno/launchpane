import AppCore
import AppKit

/// Owns drag phase transitions and the AppKit pointer retained across folder handoffs.
/// Preview geometry and persisted layout transactions remain coordinated by the root.
@MainActor final class DragInteractionCoordinator {
    private var machine = LauncherDragStateMachine()
    // LAUNCHPANE_FOLDER_EXTRACTION_POINTER_OWNERSHIP_V17
    //
    // Folder -> root extraction crosses two presentation trees while the same
    // physical mouseDown is still active. The exact NSButton that received that
    // mouseDown must remain mounted until AppKit delivers the matching mouseUp
    // or an explicit cancellation.
    //
    // Visual Folder cleanup may retire CALayers and every other hit target, but
    // it must never remove this pointer owner mid-gesture.

    // LAUNCHPANE_FOLDER_EXTRACTION_ACTIVATION_SHIELD_V21
    //
    // Folder -> root extraction temporarily keeps an AppKit button from the
    // closing Folder alive while the root drag pipeline takes over. AppKit can
    // emit a transient didResignActive during that ownership handoff even though
    // the user never switched applications. Keep a narrowly-scoped shield until
    // both pointer ownership and the root drag commit have finished.

    // LAUNCHPANE_FOLDER_DRAG_RELEASE_OWNERSHIP_V22
    //
    // A Folder-child drag temporarily owns one AppKit NSButton independently
    // from the Folder page surface that is being reordered/rebuilt. Releasing
    // that button used to create a tiny ownership gap at the end of the landing
    // animation. On an LSUIElement/accessory app, AppKit can report a transient
    // resign-active in exactly that gap, which Launchpad interprets as an
    // external app switch and dismisses the whole window.
    //
    // Suppress dismissal for the complete internal handoff, not only for
    // Folder -> root extraction. The predicate is intentionally state-derived
    // so it cannot remain stuck after an interaction finishes.
    private(set) var preservedButton: AppTileButton?
    private(set) var isExtracting = false

    var state: LauncherDragState { machine.state }

    @discardableResult func pointerDown(on item: LauncherLayoutItemIdentifier) -> Bool {
        machine.pointerDown(on: item)
    }

    @discardableResult func beginDragging() -> Bool { machine.beginDragging() }
    @discardableResult func update(target: LauncherDropTarget) -> Bool { machine.update(target: target) }
    @discardableResult func beginCommit() -> Bool { machine.beginCommit() }
    @discardableResult func beginRollback() -> Bool { machine.beginRollback() }
    func finish() { machine.finish() }

    func suppressesDismissal(hasFolderDrag: Bool, hasFolderCommit: Bool) -> Bool {
        isExtracting || preservedButton != nil || hasFolderDrag || hasFolderCommit
    }

    func preserve(_ button: AppTileButton?) { preservedButton = button }
    func beginExtraction() { isExtracting = true }
    func endExtraction() { isExtracting = false }

    func discardPointerForIdle() {
        preservedButton?.endPointerTrackingWithoutCallback()
        preservedButton?.removeFromSuperview()
        preservedButton = nil
        isExtracting = false
    }

    func retireAfterPointerCallback(_ button: PointerTrackingTileButton) {
        button.isEnabled = false
        button.isHidden = true

        Task { @MainActor [weak self, weak button] in
            // A cancellation path can still originate inside the AppKit
            // pointer callback. Yield one MainActor turn before detaching.
            await Task.yield()
            guard let button else { return }
            button.endPointerTrackingWithoutCallback()
            button.removeFromSuperview()

            // LAUNCHPANE_FOLDER_DRAG_RELEASE_OWNERSHIP_V22
            // Keep the pointer-owner sentinel alive for one additional main
            // turn after removal. didResignActive / click-through side effects
            // caused by AppKit teardown can be delivered synchronously or on
            // the following turn; clearing ownership before that reopened the
            // exact dismissal race this helper is meant to close.
            await Task.yield()
            if self?.preservedButton === button { self?.preservedButton = nil }
            self?.isExtracting = false
        }
    }
}
