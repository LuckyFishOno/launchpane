import AppCore
import CoreGraphics
import LayoutCore

/// Resolves a snapshot of visible geometry without owning views, timers, or persistence.
enum DragTargetResolver {
    struct Result {
        let insertion: LauncherDropTarget
        let merge: LauncherDropTarget?
        var isMovingTowardMerge = false
    }

    struct Motion {
        let icon: CGRect
        let previousIcon: CGRect?
    }

    struct InsertionContext {
        let source: LauncherLayoutItemIdentifier
        let page: Int
        let activeDragPage: Int
        let sourceCenter: CGPoint?
        let pageIdentifiers: [LauncherLayoutItemIdentifier]
        let visibleIdentifiers: [LauncherLayoutItemIdentifier]
        let metrics: GridMetrics
    }

    static func resolveMerge(
        insertion: LauncherDropTarget, motion: Motion, candidate: LauncherDropTarget?,
        targets: [FolderMergeGeometry.Target<LauncherLayoutItemIdentifier>]
    ) -> Result {
        let retaining: LauncherLayoutItemIdentifier?
        switch candidate {
        case .application(let identity): retaining = .application(identity)
        case .folder(let folderID): retaining = .folder(folderID)
        default: retaining = nil
        }
        // Only visible icons participate. Old snapshot slots remain exclusively
        // rollback data, never invisible merge anchors after an exchange.
        let selected = FolderMergeGeometry.target(draggedIcon: motion.icon, targets: targets, retaining: retaining)
        let merge: LauncherDropTarget?
        switch selected {
        case .application(let identity): merge = .application(identity)
        case .folder(let folderID): merge = .folder(folderID)
        case nil: merge = nil
        }
        if merge == nil, FolderMergeGeometry.isApproachingTarget(draggedIcon: motion.icon, targets: targets) {
            return DragTargetResolver.Result(insertion: .outside, merge: nil)
        }
        let approaching = FolderMergeGeometry.isMovingTowardTarget(
            draggedIcon: motion.icon, previousDraggedIcon: motion.previousIcon, targets: targets)
        return DragTargetResolver.Result(insertion: insertion, merge: merge, isMovingTowardMerge: approaching)
    }

    static func resolveInsertion(rawSlot: Int, draggedIcon: CGRect, context: InsertionContext) -> LauncherDropTarget {
        let slot = stabilizedSlot(rawSlot, draggedIcon: draggedIcon, context: context)
        let countWithoutSource = context.pageIdentifiers.filter { $0 != context.source }.count
        guard let index = ResolvedLaunchpadInsertionIndex.resolve(
            visibleSlot: min(slot, countWithoutSource), pageIdentifiers: context.pageIdentifiers,
            visibleIdentifiers: context.visibleIdentifiers, sourceIdentifier: context.source) else { return .outside }
        return .pageInsertion(page: context.page, index: index)
    }

    private static func stabilizedSlot(_ rawSlot: Int, draggedIcon: CGRect, context: InsertionContext) -> Int {
        let metrics = context.metrics
        guard context.activeDragPage == context.page, let sourceCenter = context.sourceCenter,
            let currentSlot = (0..<metrics.itemsPerPage).first(where: {
                metrics.cellFrame(forItemAt: $0)?.contains(sourceCenter) == true
            }), rawSlot != currentSlot,
            let rawCell = metrics.cellFrame(forItemAt: rawSlot) else { return rawSlot }
        return GridReorderInsertion.resolve(
            rawSlot: rawSlot, currentSlot: currentSlot, draggedCenterX: draggedIcon.midX,
            targetCell: rawCell, isRightToLeft: metrics.isRightToLeft)
    }
}
