import AppCore
import AppKit
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    struct MergeReflowContext {
        let oldPositions: [LauncherLayoutItemIdentifier: CGPoint]
        let applicationTargetPosition: CGPoint?
        let pageByIdentifier: [LauncherLayoutItemIdentifier: Int]
        let metrics: GridMetrics
        let transition: LaunchpadVisualStyle.DragReflowTransition
        let enabled: Bool
        let startTime: CFTimeInterval
    }

    func prepareFolderMergeReflowPreviewIfNeeded(_ session: LaunchpadDragSession) {
        guard session.folderCreationPreview == nil, let metrics = currentMetrics,
            !session.hasCrossedPages || session.previewSurface != nil
        else { return }

        switch session.target {
        case .application, .folder: break
        case .insertion, .pageInsertion, .outside: return
        }

        let projection = pageProjection(metrics: metrics, document: session.draft.document)
        guard projection.pages.indices.contains(currentPage) else { return }

        let items = projection.items
        let scale = window?.backingScaleFactor ?? 1
        let oldSurface = session.previewSurface ?? session.originalSurface
        guard oldSurface.pageIndex == currentPage else { return }

        // Freeze the merge destination before the final layout starts moving.
        // The source app must finish shrinking into the folder at the folder's
        // current visible position; only after that handoff may the page compact.
        freezeMergeLandingTarget(session, surface: oldSurface)

        let newSurface = makePageSurface(
            pageIndex: currentPage, items: items, metrics: metrics, scale: scale, projection: projection)

        let oldPositions = visibleTilePositions(in: oldSurface)

        let applicationTargetPosition: CGPoint? = {
            guard case .application(let identity) = session.target else { return nil }
            return oldPositions[.application(identity)]
        }()

        // LAUNCHPANE_CROSS_PAGE_ENTERING_HANDOFF_V3
        // oldSurface is the live pre-merge projection after edge paging. Remember
        // which page owned each item so a tile pulled in from an adjacent page
        // can receive a real visual handoff instead of appearing directly on top
        // of the tile that is still occupying the final slot.
        let preMergePageByIdentifier = preMergePageMapping(session, metrics: metrics)

        let transition = LaunchpadVisualStyle.dragReflowTransition(movedForward: false)
        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let mergeLandingDuration = LaunchpadVisualStyle.dragCompletionTransition(kind: .merge).duration
        let reflowStartTime =
            CACurrentMediaTime() + mergeLandingDuration + FolderMergeVisualMetrics.postLandingReflowDelay

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        newSurface.layer.frame = bounds
        newSurface.layer.contentsScale = scale
        newSurface.layer.opacity = 1
        newSurface.layer.isHidden = false

        let reflow = MergeReflowContext(
            oldPositions: oldPositions, applicationTargetPosition: applicationTargetPosition,
            pageByIdentifier: preMergePageByIdentifier, metrics: metrics, transition: transition,
            enabled: shouldAnimate, startTime: reflowStartTime)
        for entry in newSurface.entries { animateMergeReflowEntry(entry, session: session, reflow: reflow) }

        restoreMergedFolderScale(session, surface: newSurface, animated: shouldAnimate)

        // Swap render ownership atomically. Every surviving tile in the new
        // surface starts at its current presentation position, then translates
        // into the compacted slot using the same reflow animation as App swaps.
        oldSurface.layer.removeAllAnimations()
        oldSurface.layer.opacity = 0
        oldSurface.layer.isHidden = true
        oldSurface.layer.removeFromSuperlayer()

        rootLayer.insertSublayer(newSurface.layer, below: fixedOverlayLayer)

        CATransaction.commit()

        session.previewSurface = newSurface
        session.usesInPlacePreview = false
        activeSurface = newSurface
        pageContentLayer = newSurface.layer
    }

    func restoreMergedFolderScale(
        _ session: LaunchpadDragSession, surface newSurface: LaunchpadPageSurface, animated shouldAnimate: Bool
    ) {
        // App -> existing Folder leaves the same folder identifier in the final
        // document. Continue the merge-ready +30% presentation back to 1.0 on
        // the new surface instead of snapping smaller at mouse-up.
        if case .folder(let folderID) = session.target,
            let folderEntry = newSurface.entries.first(where: { $0.item.id == .folder(folderID) }), shouldAnimate {
            let scaleDown = CABasicAnimation(keyPath: "transform")
            scaleDown.fromValue = CATransform3DMakeAffineTransform(
                .init(scaleX: FolderMergeVisualMetrics.folderTargetScale, y: FolderMergeVisualMetrics.folderTargetScale)
            )
            scaleDown.toValue = CATransform3DIdentity
            scaleDown.duration = FolderMergeVisualMetrics.transitionDuration
            scaleDown.timingFunction = CAMediaTimingFunction(name: .easeOut)
            folderEntry.iconLayer.add(scaleDown, forKey: "folderMergeCommitScale")
        }

    }

    func animateMergeReflowEntry(
        _ entry: LaunchpadPageEntry, session: LaunchpadDragSession, reflow: MergeReflowContext
    ) {
        let oldPositions = reflow.oldPositions
        let applicationTargetPosition = reflow.applicationTargetPosition
        let preMergePageByIdentifier = reflow.pageByIdentifier
        let metrics = reflow.metrics
        let transition = reflow.transition
        let shouldAnimate = reflow.enabled
        let reflowStartTime = reflow.startTime
        let targetPosition = entry.tileLayer.position
        var startPosition = oldPositions[entry.item.id]

        // App -> App replaces the target application identifier with a new
        // folder identifier. Start that new folder exactly where the target
        // app is visibly sitting so the replacement does not flash in from a
        // different slot while the rest of the page compacts.
        if startPosition == nil, let applicationTargetPosition, case .folder(let folder) = entry.item,
            case .application(let targetIdentity) = session.target,
            folder.applications.contains(where: { $0.id == targetIdentity }) {
            startPosition = applicationTargetPosition
        }

        // A genuine page-entering item has no old position on this surface.
        // Before this fix it therefore appeared immediately at targetPosition while
        // the previous last tile was held at that exact slot until reflowStartTime.
        // Stage it in the adjacent-page direction and keep it invisible until the
        // outgoing tile has visibly vacated the slot.
        if startPosition == nil, let previousPage = preMergePageByIdentifier[entry.item.id],
            previousPage != currentPage {
            let logicalDirection: CGFloat = previousPage > currentPage ? 1 : -1
            let visualDirection = metrics.isRightToLeft ? -logicalDirection : logicalDirection
            let enteringOffset = abs(transition.enteringItemOffset) * visualDirection

            startPosition = CGPoint(x: targetPosition.x + enteringOffset, y: targetPosition.y)

            if shouldAnimate {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = transition.enteringItemFadeDuration
                // Position starts moving with the grid. Opacity deliberately waits
                // for about the first third of the current reflow so two icons never
                // read as owners of the same bottom-right slot.
                fade.beginTime = reflowStartTime + min(transition.duration * 0.33, 0.16)
                fade.timingFunction = transition.timingFunction
                fade.fillMode = .backwards
                entry.tileLayer.add(fade, forKey: "dragReflowOpacity")
            }
        }

        guard shouldAnimate, let startPosition, startPosition != targetPosition else { return }

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: startPosition)
        move.toValue = NSValue(point: targetPosition)
        move.duration = transition.duration
        move.timingFunction = transition.timingFunction
        move.beginTime = reflowStartTime
        move.fillMode = .backwards
        entry.tileLayer.add(move, forKey: "dragReflowPosition")
    }
}
