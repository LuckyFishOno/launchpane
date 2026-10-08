import AppCore
import AppKit
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    func applyDropHighlight(to entry: LaunchpadPageEntry, mergeTarget: LauncherLayoutItemIdentifier?) {
        let isMergeTarget = entry.item.id == mergeTarget
        let isApplicationTarget: Bool
        let isFolderTarget: Bool
        switch entry.item {
        case .application:
            isApplicationTarget = isMergeTarget
            isFolderTarget = false
        case .folder:
            isApplicationTarget = false
            isFolderTarget = isMergeTarget
        }

        // Restore the normal selection style before applying merge-ready visuals.
        entry.selectionLayer.backgroundColor =
            NSColor.white.withAlphaComponent(FolderMergeVisualMetrics.normalSelectionBackgroundOpacity).cgColor
        entry.selectionLayer.borderColor =
            NSColor.white.withAlphaComponent(FolderMergeVisualMetrics.normalSelectionBorderOpacity).cgColor
        entry.selectionLayer.borderWidth = FolderMergeVisualMetrics.normalSelectionBorderWidth
        entry.selectionLayer.setAffineTransform(.identity)

        if isApplicationTarget {
            // App -> App: keep both app icons visible. Add a compact,
            // folder-colored rounded surface behind the target and only fade
            // the two names. This reads as "these apps will group" instead of
            // prematurely replacing the target with a folder.
            entry.selectionLayer.backgroundColor =
                NSColor.white.withAlphaComponent(FolderMergeVisualMetrics.folderBackgroundOpacity).cgColor
            entry.selectionLayer.borderColor =
                NSColor.white.withAlphaComponent(FolderMergeVisualMetrics.folderBorderOpacity).cgColor
            entry.selectionLayer.borderWidth = FolderMergeVisualMetrics.folderBorderWidth
            entry.selectionLayer.setAffineTransform(
                .init(
                    scaleX: FolderMergeVisualMetrics.appTargetFrameScale,
                    y: FolderMergeVisualMetrics.appTargetFrameScale))
            entry.selectionLayer.opacity = 1
            entry.iconLayer.opacity = 1
            entry.iconLayer.setAffineTransform(.identity)
            setMergeLabelOpacity(entry.labelLayer, to: 0)
        } else if isFolderTarget {
            // App -> Folder: the folder itself becomes the merge-ready surface.
            // Enlarge it to the same footprint as the App -> App preview and
            // fade both labels, without drawing a second frame around it.
            entry.selectionLayer.opacity = 0
            entry.iconLayer.opacity = 1
            entry.iconLayer.setAffineTransform(
                .init(scaleX: FolderMergeVisualMetrics.folderTargetScale, y: FolderMergeVisualMetrics.folderTargetScale)
            )
            setMergeLabelOpacity(entry.labelLayer, to: 0)
        } else {
            entry.selectionLayer.opacity = entry.absoluteIndex == selectedIndex ? 1 : 0
            entry.iconLayer.opacity = 1
            entry.iconLayer.setAffineTransform(.identity)
            setMergeLabelOpacity(entry.labelLayer, to: 1)
        }
    }

    func updateDropHighlight(_ target: LauncherDropTarget) {
        let surface = dragSession?.previewSurface ?? activeSurface
        guard let surface else { return }

        let mergeTarget: LauncherLayoutItemIdentifier?
        switch target {
        case .application(let identity): mergeTarget = .application(identity)
        case .folder(let folderID): mergeTarget = .folder(folderID)
        case .insertion, .pageInsertion, .outside: mergeTarget = nil
        }

        if let session = dragSession {
            let keepHiddenForMergeLanding: Bool
            if session.hasReleased {
                switch session.target {
                case .application, .folder: keepHiddenForMergeLanding = true
                case .insertion, .pageInsertion, .outside: keepHiddenForMergeLanding = false
                }
            } else {
                keepHiddenForMergeLanding = false
            }
            updateDragProxyMergeLabel(session, hidden: mergeTarget != nil || keepHiddenForMergeLanding)
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(FolderMergeVisualMetrics.transitionDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))

        for entry in surface.entries { applyDropHighlight(to: entry, mergeTarget: mergeTarget) }

        CATransaction.commit()
    }

    func setMergeLabelOpacity(_ labelLayer: CALayer, to targetOpacity: Float) {
        guard labelLayer.opacity != targetOpacity else { return }

        let visibleOpacity = labelLayer.presentation()?.opacity ?? labelLayer.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labelLayer.opacity = targetOpacity
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = visibleOpacity
        animation.toValue = targetOpacity
        animation.duration = FolderMergeVisualMetrics.labelFadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        labelLayer.add(animation, forKey: "folderMergeLabelOpacity")
    }

    func updateDragProxyMergeLabel(_ session: LaunchpadDragSession, hidden: Bool) {
        guard session.isSourceLabelHiddenForMerge != hidden else { return }
        session.isSourceLabelHiddenForMerge = hidden

        // Never cross-fade the moving proxy's `contents`. CATransition keeps a
        // cached copy of the old backing store while the proxy position is being
        // updated every pointer event; that cached copy stays at the transition
        // origin and produces the visible ghost left behind when the drag exits
        // a merge target. Keep the label as its own child layer instead so both
        // icon and label always share the proxy's live position.
        guard let labelLayer = DragProxyPresentation.dragProxyLabelLayer(session.proxyLayer) else { return }
        let targetOpacity: Float = hidden ? 0 : 1
        let visibleOpacity = labelLayer.presentation()?.opacity ?? labelLayer.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labelLayer.opacity = targetOpacity
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = visibleOpacity
        fade.toValue = targetOpacity
        fade.duration = FolderMergeVisualMetrics.labelFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        labelLayer.add(fade, forKey: DragProxyMetrics.labelAnimationKey)
    }

    func freezeMergeLandingTarget(
        _ session: LaunchpadDragSession, surface oldSurface: LaunchpadPageSurface) {
        let landingTargetID: LauncherLayoutItemIdentifier?
        switch session.target {
        case .application(let identity): landingTargetID = .application(identity)
        case .folder(let folderID): landingTargetID = .folder(folderID)
        case .insertion, .pageInsertion, .outside: landingTargetID = nil
        }
        if let landingTargetID, let landingEntry = oldSurface.entries.first(where: { $0.item.id == landingTargetID }) {
            session.mergeLandingTargetIconFrame = visibleIconFrame(for: landingEntry)
        } else {
            session.mergeLandingTargetIconFrame = nil
        }

    }

    func preMergePageMapping(_ session: LaunchpadDragSession, metrics: GridMetrics)
        -> [LauncherLayoutItemIdentifier: Int] {
        guard session.hasCrossedPages else { return [:] }

        let preMergeDocument = session.projectedDocument ?? session.projectionBaselineDocument
        let preMergeProjection = pageProjection(metrics: metrics, document: preMergeDocument)

        var result: [LauncherLayoutItemIdentifier: Int] = [:]
        for (pageIndex, page) in preMergeProjection.pages.enumerated() {
            for item in page { result[item.id] = pageIndex }
        }
        return result
    }

    func visibleTilePositions(
        in oldSurface: LaunchpadPageSurface
    ) -> [LauncherLayoutItemIdentifier: CGPoint] {
        var oldPositions: [LauncherLayoutItemIdentifier: CGPoint] = [:]
        for entry in oldSurface.entries {
            oldPositions[entry.item.id] = entry.tileLayer.presentation()?.position ?? entry.tileLayer.position
        }

        return oldPositions
    }
}
