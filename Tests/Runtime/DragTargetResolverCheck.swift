import AppCore
import DisplayCore
import Foundation
import LayoutCore

@main struct DragTargetResolverCheck {
    static func main() {
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }
        checkMerge(check)
        checkInsertion(check)
        print("DRAG TARGET RESOLVER: \(assertions) assertions passed")
    }

    private static func checkMerge(_ check: (Bool, String) -> Void) {
        let folderID = UUID()
        let icon = CGRect(x: 200, y: 200, width: 100, height: 100)
        let targets = [FolderMergeGeometry.Target(
            id: LauncherLayoutItemIdentifier.folder(folderID), iconFrame: icon,
            cellFrame: icon.insetBy(dx: -100, dy: -100))]
        let insertion = LauncherDropTarget.pageInsertion(page: 1, index: 3)
        func resolve(_ frame: CGRect, previous: CGRect? = nil) -> DragTargetResolver.Result {
            DragTargetResolver.resolveMerge(
                insertion: insertion, motion: .init(icon: frame, previousIcon: previous),
                candidate: nil, targets: targets)
        }
        let centered = resolve(icon)
        check(centered.merge == .folder(folderID), "Centered overlap selects the visible folder")
        check(centered.insertion == insertion, "Quick release retains its insertion fallback")
        let approaching = resolve(icon.offsetBy(dx: 55, dy: 0))
        check(approaching.merge == nil && approaching.insertion == .outside, "Approach zone suppresses early reorder")
        let moving = resolve(icon.offsetBy(dx: 90, dy: 90), previous: icon.offsetBy(dx: 95, dy: 95))
        check(moving.isMovingTowardMerge && moving.insertion == insertion,
            "Diagonal motion preserves the pending target")
        let stationary = resolve(icon.offsetBy(dx: 90, dy: 90), previous: icon.offsetBy(dx: 90, dy: 90))
        check(!stationary.isMovingTowardMerge, "Stationary gutter holds can finish reorder dwell")
        let missing = DragTargetResolver.resolveMerge(
            insertion: insertion, motion: .init(icon: icon, previousIcon: nil),
            candidate: .folder(folderID), targets: [])
        check(missing.merge == nil && missing.insertion == insertion,
            "An old candidate cannot resurrect a hidden target")
    }

    private static func checkInsertion(_ check: (Bool, String) -> Void) {
        let items = (0..<4).map { _ in LauncherLayoutItemIdentifier.folder(UUID()) }
        let source = LauncherLayoutItemIdentifier.folder(UUID())
        for rtl in [false, true] {
            let frame = CGRect(x: 0, y: 0, width: 1710, height: 1107)
            let display = DisplayContext(displayID: 0, frame: frame, visibleFrame: frame, backingScaleFactor: 2)
            let metrics = LayoutConstraintSolver().solve(
                display: display, requested: UserLayoutPreferences(isRightToLeft: rtl), itemCount: items.count)
            let context = DragTargetResolver.InsertionContext(
                source: source, page: 2, activeDragPage: 0, sourceCenter: nil,
                pageIdentifiers: items, visibleIdentifiers: items, metrics: metrics)
            for slot in 0..<items.count {
                let cell = metrics.cellFrame(forItemAt: slot)!
                let result = DragTargetResolver.resolveInsertion(rawSlot: slot, draggedIcon: cell, context: context)
                check(result == .pageInsertion(page: 2, index: slot),
                    "Cross-page insertion preserves order in LTR and RTL")
            }
            let trailing = DragTargetResolver.resolveInsertion(rawSlot: 20, draggedIcon: .zero, context: context)
            check(trailing == .pageInsertion(page: 2, index: 4), "Trailing empty slots clamp to append")
        }
    }
}
