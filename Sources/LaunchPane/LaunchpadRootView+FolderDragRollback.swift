import AppCore
import AppKit
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    struct FolderRollbackTransition {
        let outgoing: FolderPageSurface?
        let restored: FolderPageSurface
        let metrics: FolderGridMetrics
        let baselineFolder: ResolvedLaunchpadFolder
        let scale: CGFloat
        let resting: CGPoint
        let width: CGFloat
        let visualDirection: CGFloat
    }

    func cancelFolderItemDragBeforeExit(animated: Bool) {
        pendingFolderPress = nil
        guard let context = folderItemDragSession else {
            dragInteraction.finish()
            return
        }
        cancelFolderItemDragEdgePaging(context)
        if context.hasCrossedPages, folderPaging.page != context.sourcePage {
            finishFolderCrossPageRollback(context, animated: animated)
            return
        }
        folderItemDragSession = nil
        folderHiddenApplicationID = nil
        // Keep dragInteraction.preservedButton until the rollback has restored
        // a live hit target. Clearing it here re-opened the same transient
        // resign-active gap as a committed drop.
        restoreFolderItemReorderPreview(context, animated: animated)
        _ = dragInteraction.beginRollback()

        let finish = folderRollbackCompletion(context)

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate else {
            finish()
            return
        }
        let transition = LaunchpadVisualStyle.dragCompletionTransition(kind: .rollback)
        CATransaction.begin()
        CATransaction.setAnimationDuration(transition.duration)
        CATransaction.setAnimationTimingFunction(transition.timingFunction)
        context.proxyLayer.position = context.sourceEntry.frames.cell.center
        context.proxyLayer.setAffineTransform(.identity)
        context.proxyLayer.opacity = 1
        CATransaction.commit()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(transition.duration))
            finish()
        }
    }

    func folderRollbackCompletion(_ context: FolderItemDragSession) -> @MainActor () -> Void {
        let sourceParent = context.sourceTileParent
        let sourceIndex = context.sourceTileIndex
        let proxy = context.proxyLayer
        let sourceLayer = context.sourceEntry.tileLayer
        let iconLayer = context.sourceEntry.iconLayer
        return { [weak self, weak proxy, weak sourceLayer, weak iconLayer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            // Return the real folder child before retiring the proxy. Both
            // mutations commit together, so visual ownership never drops to zero.
            if let sourceLayer, sourceLayer.superlayer == nil {
                let currentCount = sourceParent.sublayers?.count ?? 0
                let restoredIndex = UInt32(min(max(sourceIndex, 0), currentCount))
                sourceParent.insertSublayer(sourceLayer, at: restoredIndex)
            }
            sourceLayer?.opacity = 1
            iconLayer?.removeAnimation(forKey: "iconPressedOpacity")
            iconLayer?.opacity = 1
            iconLayer?.setAffineTransform(.identity)

            self?.restoreFolderPointerOwnerAfterRollback(context)

            proxy?.removeAllAnimations()
            proxy?.removeFromSuperlayer()
            CATransaction.commit()
            self?.dragInteraction.finish()
        }

    }

    func restoreFolderPointerOwnerAfterRollback(_ context: FolderItemDragSession) {
        // A drag can travel far enough for its original page surface to
        // be evicted and rebuilt. Reveal whichever source presentation
        // is current, and retire the old transparent AppKit pointer owner
        // if that rebuilt surface owns a different button.
        self.folderHiddenApplicationID = nil
        if case .application(let application) = context.sourceEntry.item,
            let livePresentation = self.folderPresentation.folderPresentations.first(where: {
                $0.button.application.id == application.id
            }) {
            livePresentation.tileLayer.opacity = 1
            livePresentation.button.isHidden = false
            livePresentation.button.isEnabled = true
            if livePresentation.button === context.trackingButton {
                // Same surface/button regained ownership; no AppKit view
                // teardown is needed at all.
                context.trackingButton.endPointerTrackingWithoutCallback()
                self.dragInteraction.preserve(nil)
            } else {
                self.retireFolderTrackingButtonAfterPointerCallback(context.trackingButton)
            }
        } else {
            self.retireFolderTrackingButtonAfterPointerCallback(context.trackingButton)
        }

    }

    func finishFolderCrossPageRollback(_ context: FolderItemDragSession, animated: Bool) {
        guard folderItemDragSession === context, let folder = resolvedFolder(id: context.folderID),
            let viewportLayer = folderPaging.viewportLayer
        else {
            folderItemDragSession = nil
            dragInteraction.finish()
            return
        }

        _ = dragInteraction.beginRollback()
        context.edgePagingGeneration &+= 1
        context.edgePagingTask?.cancel()
        context.edgePagingTask = nil
        context.isEdgePageTurnInFlight = true

        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: context.baselineApplications.count)
        let scale = window?.backingScaleFactor ?? displayContext.backingScaleFactor
        let baselineFolder = ResolvedLaunchpadFolder(
            id: folder.id, title: folder.title, applications: context.baselineApplications)
        let built = makeFolderPageLayer(
            folder: baselineFolder, metrics: metrics, pageIndex: context.sourcePage, scale: scale)
        let restored = FolderPageSurface(
            pageIndex: context.sourcePage, layer: built.layer, presentations: built.presentations,
            applications: built.applications)
        hideFolderDragSource(in: restored, context: context)

        let outgoing = folderPaging.surfaces[folderPaging.page]
        let resting = metrics.panelFrame.center
        let width = max(1, metrics.panelFrame.width)
        let direction = context.sourcePage < folderPaging.page ? -1 : 1
        let visualDirection = CGFloat(metrics.isRightToLeft ? -direction : direction)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing?.layer.removeAllAnimations()
        outgoing?.layer.position = resting
        outgoing?.layer.isHidden = false
        restored.layer.removeAllAnimations()
        restored.layer.position = CGPoint(x: resting.x + visualDirection * width, y: resting.y)
        restored.layer.isHidden = false
        if restored.layer.superlayer == nil { viewportLayer.addSublayer(restored.layer) }
        CATransaction.commit()

        let transition = FolderRollbackTransition(
            outgoing: outgoing, restored: restored, metrics: metrics, baselineFolder: baselineFolder, scale: scale,
            resting: resting, width: width, visualDirection: visualDirection)
        let finishPageReturn: @MainActor () -> Void = { [weak self, weak context] in
            guard let self, let context, self.folderItemDragSession === context else { return }
            self.finishFolderPageReturn(context, transition: transition, animated: animated)
        }
        animateFolderPageReturn(transition, animated: animated, finishPageReturn: finishPageReturn)
    }

    func finishFolderPageReturn(
        _ context: FolderItemDragSession, transition: FolderRollbackTransition, animated: Bool
    ) {
        let outgoing = transition.outgoing
        let restored = transition.restored
        let resting = transition.resting
        let metrics = transition.metrics
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing?.layer.removeAllAnimations()
        outgoing?.layer.removeFromSuperlayer()
        restored.layer.removeAllAnimations()
        restored.layer.position = resting
        CATransaction.commit()

        self.folderPaging.selectPage(context.sourcePage)
        if let outgoing { self.detachFolderButtons(from: outgoing) }
        self.folderPaging.surfaces.removeAll(keepingCapacity: true)
        self.folderPaging.surfaces[context.sourcePage] = restored
        self.folderPresentation.folderPresentations = restored.presentations
        self.updateFolderPageIndicator(pageCount: metrics.pageCount)

        let sourceLocalIndex = context.sourceAbsoluteIndex - context.sourcePage * metrics.itemsPerPage
        let destination =
            self.folderPageItemFrames(
                localIndex: sourceLocalIndex, visibleCount: restored.applications.count, metrics: metrics)?.cell.center
            ?? context.sourceEntry.frames.cell.center
        let style = LaunchpadVisualStyle.dragCompletionTransition(kind: .rollback)
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? style.duration : 0

        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(style.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        context.proxyLayer.position = destination
        context.proxyLayer.setAffineTransform(.identity)
        context.proxyLayer.opacity = 1
        CATransaction.commit()

        Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            self.finishFolderRollbackLanding(context, transition: transition)
        }
    }

    func finishFolderRollbackLanding(
        _ context: FolderItemDragSession, transition: FolderRollbackTransition) {
        let restored = transition.restored
        let metrics = transition.metrics
        let baselineFolder = transition.baselineFolder
        let scale = transition.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        context.proxyLayer.removeAllAnimations()
        context.proxyLayer.removeFromSuperlayer()
        self.folderHiddenApplicationID = nil
        if case .application(let sourceApplication) = context.sourceEntry.item,
            let livePresentation = restored.presentations.first(where: {
                $0.button.application.id == sourceApplication.id
            }) {
            livePresentation.tileLayer.opacity = 1
            self.attachFolderButtons(to: restored, hidden: false)
        }
        if restored.presentations.contains(where: { $0.button === context.trackingButton }) {
            context.trackingButton.endPointerTrackingWithoutCallback()
            context.trackingButton.isHidden = false
            context.trackingButton.isEnabled = true
            self.dragInteraction.preserve(nil)
        } else {
            self.retireFolderTrackingButtonAfterPointerCallback(context.trackingButton)
        }
        CATransaction.commit()
        self.folderItemDragSession = nil
        self.pendingFolderPress = nil
        self.dragInteraction.finish()
        self.stageAdjacentFolderPageSurfaces(folder: baselineFolder, metrics: metrics, scale: scale)
    }

    func animateFolderPageReturn(
        _ transition: FolderRollbackTransition, animated: Bool, finishPageReturn: @escaping @MainActor () -> Void
    ) {
        let outgoing = transition.outgoing
        let restored = transition.restored
        let resting = transition.resting
        let width = transition.width
        let visualDirection = transition.visualDirection
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishPageReturn()
            return
        }
        let timing = CAMediaTimingFunction(controlPoints: 0.24, 0.12, 0.28, 1)
        func animation(_ start: CGPoint, _ end: CGPoint) -> CABasicAnimation {
            let result = CABasicAnimation(keyPath: "position")
            result.fromValue = NSValue(point: start)
            result.toValue = NSValue(point: end)
            result.duration = DragEdgeMetrics.pageDuration
            result.timingFunction = timing
            return result
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { Task { @MainActor in finishPageReturn() } }
        let outgoingEnd = CGPoint(x: resting.x - visualDirection * width, y: resting.y)
        outgoing?.layer.position = outgoingEnd
        restored.layer.position = resting
        if let outgoing { outgoing.layer.add(animation(resting, outgoingEnd), forKey: "folderCrossPageRollbackOut") }
        restored.layer.add(
            animation(CGPoint(x: resting.x + visualDirection * width, y: resting.y), resting),
            forKey: "folderCrossPageRollbackIn")
        CATransaction.commit()
    }
}
