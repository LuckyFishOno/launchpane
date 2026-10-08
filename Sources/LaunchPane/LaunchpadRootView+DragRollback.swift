import AppCore
import AppKit
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    func animateRollbackTiles(
        from previewSurface: LaunchpadPageSurface, to originalSurface: LaunchpadPageSurface,
        excluding sourceID: LauncherLayoutItemIdentifier, transition: LaunchpadVisualStyle.DragCompletionTransition
    ) {
        var originalPositions: [LauncherLayoutItemIdentifier: CGPoint] = [:]
        for entry in originalSurface.entries { originalPositions[entry.item.id] = entry.frames.cell.center }

        for entry in previewSurface.entries where entry.item.id != sourceID {
            guard let targetPosition = originalPositions[entry.item.id] else { continue }

            let visiblePosition = entry.tileLayer.presentation()?.position ?? entry.tileLayer.position

            entry.tileLayer.removeAnimation(forKey: "dragReflowPosition")

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            entry.tileLayer.position = targetPosition
            CATransaction.commit()

            guard visiblePosition != targetPosition else { continue }

            let rollback = CABasicAnimation(keyPath: "position")
            rollback.fromValue = NSValue(point: visiblePosition)
            rollback.toValue = NSValue(point: targetPosition)
            rollback.duration = transition.duration
            rollback.timingFunction = transition.timingFunction
            entry.tileLayer.add(rollback, forKey: "dragRollbackPosition")
        }
    }

    func finishCrossPageRollback(
        _ session: LaunchpadDragSession, animated: Bool, completion: @escaping () -> Void
    ) {
        session.edgeIncomingSurface?.layer.removeAllAnimations()
        session.edgeIncomingSurface?.layer.removeFromSuperlayer()
        session.edgeOutgoingSurface?.layer.removeAllAnimations()
        session.edgeOutgoingSurface?.layer.removeFromSuperlayer()
        session.previewSurface?.layer.removeFromSuperlayer()
        session.originalSurface.layer.removeFromSuperlayer()
        detachButtons(from: session.originalSurface)
        session.isEdgePageTransitionActive = false
        layoutDocument = session.draft.snapshot
        currentPage = session.sourcePage
        selectedIndex = -1
        invalidatePageSurfaceCache()
        guard let metrics = currentMetrics else {
            session.proxyLayer.removeFromSuperlayer()
            completion()
            return
        }
        let scale = window?.backingScaleFactor ?? 1
        let configuration = PageSurfaceConfiguration(
            bounds: bounds, scale: scale, contentRevision: contentRevision, metrics: metrics)
        rebuildPageSurfaces(items: resolvedItems, metrics: metrics, scale: scale, configuration: configuration)
        guard let restored = pageSurfaces[currentPage],
            let source = restored.entries.first(where: { $0.item.id == session.sourceEntry.item.id })
        else {
            session.proxyLayer.removeFromSuperlayer()
            completion()
            return
        }
        activeSurface = restored
        pageContentLayer = restored.layer
        rootLayer.insertSublayer(restored.layer, below: fixedOverlayLayer)
        source.tileLayer.removeFromSuperlayer()
        updatePageIndicator(pageCount: pageProjection(metrics: metrics).pageCount, metrics: metrics, scale: scale)
        animateCrossPageRollback(
            session, source: source, restored: restored, animated: animated, completion: completion)
    }

    func animateCrossPageRollback(
        _ session: LaunchpadDragSession, source: LaunchpadPageEntry, restored: LaunchpadPageSurface, animated: Bool,
        completion: @escaping () -> Void
    ) {
        let proxy = session.proxyLayer
        refreshDragProxyForRelease(proxy, sourceEntry: session.sourceEntry)
        let start = proxy.presentation()?.position ?? proxy.position
        let end = source.frames.cell.center
        let style = LaunchpadVisualStyle.dragCompletionTransition(kind: .rollback)
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? style.duration : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        proxy.removeAllAnimations()
        proxy.position = end
        if duration > 0 {
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: start)
            move.toValue = NSValue(point: end)
            move.duration = duration
            move.timingFunction = style.timingFunction
            proxy.add(move, forKey: "crossPageRollback")
        }
        CATransaction.commit()
        dragVisuals.schedule(for: proxy, after: duration) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            proxy.removeFromSuperlayer()
            restored.layer.addSublayer(source.tileLayer)
            CATransaction.commit()
            completion()
        }
    }
}
