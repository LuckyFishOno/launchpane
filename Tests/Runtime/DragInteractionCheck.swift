import AppCore
import AppKit

@main struct DragInteractionCheck {
    @MainActor static func main() async {
        _ = NSApplication.shared
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }
        let owner = DragInteractionCoordinator()
        let button = makeButton()
        let host = NSView()
        host.addSubview(button)
        let item = LauncherLayoutItemIdentifier.application(button.application.id)
        check(owner.pointerDown(on: item) && owner.beginDragging(), "Press enters the drag state")
        check(!owner.pointerDown(on: item), "A second press cannot replace an active drag")
        check(!owner.beginCommit(), "A drag without a valid destination cannot commit")
        check(owner.update(target: .pageInsertion(page: 0, index: 1)), "Valid destination updates the drag")
        check(owner.beginCommit() && owner.beginRollback(), "Commit failure can enter rollback")
        owner.preserve(button)
        owner.beginExtraction()
        owner.finish()
        check(owner.state == .idle && owner.preservedButton === button,
            "Finishing the model preserves the pointer handoff")
        check(owner.suppressesDismissal(hasFolderDrag: false, hasFolderCommit: false),
            "Pointer handoff shields dismissal")
        owner.retireAfterPointerCallback(button)
        check(button.isHidden && !button.isEnabled, "Retirement immediately disables the old target")
        check(button.superview === host && owner.preservedButton === button,
            "Retirement waits for event dispatch to unwind")
        for _ in 0..<100 where owner.preservedButton != nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
        check(button.superview == nil && owner.preservedButton == nil,
            "Deferred retirement detaches and releases the target")
        check(!owner.isExtracting, "Retirement releases the extraction shield")
        check(!owner.suppressesDismissal(hasFolderDrag: false, hasFolderCommit: false), "Idle permits normal dismissal")
        check(owner.suppressesDismissal(hasFolderDrag: true, hasFolderCommit: false), "Folder drag shields dismissal")
        check(owner.suppressesDismissal(hasFolderDrag: false, hasFolderCommit: true), "Folder commit shields dismissal")
        host.addSubview(button)
        owner.preserve(button)
        owner.beginExtraction()
        owner.discardPointerForIdle()
        check(owner.preservedButton == nil && button.superview == nil && !owner.isExtracting,
            "Idle releases pointer resources")
        owner.discardPointerForIdle()
        check(owner.preservedButton == nil, "Idle cleanup is repeatable")
        print("DRAG INTERACTION: \(assertions) assertions passed")
    }

    @MainActor private static func makeButton() -> AppTileButton {
        AppTileButton(application: ApplicationRecord(
            displayName: "Drag", bundleIdentifier: "test.drag.owner",
            bundleURL: URL(fileURLWithPath: "/Applications/TestDrag.app")))
    }
}
