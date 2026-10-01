import AppCore
import AppKit
import LayoutCore
import QuartzCore

/// Folder-local commit and rollback handoffs. Geometry and preview updates stay
/// with the active drag; transaction completion uses the shared commit policy.
extension LaunchpadRootView {
    func completeFolderItemReorder(_ context: FolderItemDragSession, at center: CGPoint) {
        guard folderItemDragSession === context else { return }
        updateFolderDropPreview(context, at: center)

        guard context.destinationAbsoluteIndex != context.sourceAbsoluteIndex, let geometry = folderReorderGeometry(),
            geometry.folder.id == context.folderID, case .application(let sourceApplication) = context.sourceEntry.item
        else {
            cancelFolderItemDragBeforeExit(animated: true)
            return
        }

        let draft: LauncherLayoutDraft
        do {
            var candidate = try LauncherLayoutDraft(document: layoutDocument)
            try candidate.moveApplication(
                sourceApplication.id, inFolder: context.folderID, toIndex: context.destinationAbsoluteIndex)
            guard candidate.hasChanges else {
                cancelFolderItemDragBeforeExit(animated: true)
                return
            }
            draft = candidate
        } catch {
            NSSound.beep()
            cancelFolderItemDragBeforeExit(animated: true)
            return
        }

        let destinationLocalIndexForState = max(0, context.destinationAbsoluteIndex - geometry.pageStartIndex)
        _ = dragInteraction.update(
            target: .pageInsertion(page: folderPaging.page, index: destinationLocalIndexForState))
        guard dragInteraction.beginCommit() else {
            cancelFolderItemDragBeforeExit(animated: true)
            return
        }

        cancelFolderItemDragEdgePaging(context)
        folderItemDragSession = nil
        pendingFolderPress = nil
        folderReorderCommit.begin(context)
        isCommittingLayout = true
        context.trackingButton.isEnabled = false
        context.trackingButton.isHidden = true

        let destinationLocalIndex = context.destinationAbsoluteIndex - geometry.pageStartIndex
        let destinationCenter =
            folderPageItemFrames(
                localIndex: destinationLocalIndex, visibleCount: geometry.visibleCount, metrics: geometry.metrics)?.cell
            .center ?? context.proxyLayer.position

        let (landingStartMediaTime, landingDuration) = animateFolderReorderLanding(context, to: destinationCenter)

        Task { @MainActor [weak self] in
            guard let self else { return }
            await persistFolderReorder(
                context, draft: draft, landingStartMediaTime: landingStartMediaTime, landingDuration: landingDuration)
        }
    }

    func animateFolderReorderLanding(_ context: FolderItemDragSession, to destinationCenter: CGPoint) -> (
        CFTimeInterval, CFTimeInterval
    ) {
        // Match the root-grid committed insertion landing exactly.
        // The old Folder-local 0.12 s ease-out made the dragged child snap
        // noticeably faster than the surrounding root-style reflow.
        let landingTransition = LaunchpadVisualStyle.dragCompletionTransition(kind: .insertion)
        let landingDuration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : landingTransition.duration
        let landingStartMediaTime = CACurrentMediaTime()

        CATransaction.begin()
        if landingDuration > 0 {
            CATransaction.setAnimationDuration(landingDuration)
            CATransaction.setAnimationTimingFunction(landingTransition.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        context.proxyLayer.position = destinationCenter
        context.proxyLayer.setAffineTransform(.identity)
        context.proxyLayer.opacity = 1
        CATransaction.commit()

        return (landingStartMediaTime, landingDuration)
    }

    func persistFolderReorder(
        _ context: FolderItemDragSession, draft: LauncherLayoutDraft, landingStartMediaTime: CFTimeInterval,
        landingDuration: CFTimeInterval
    ) async {
        do {
            let committedDocument = try await layoutStore.commit(draft)

            folderReorderCommit.markPersistenceFinished(context)

            // A fast layout-store write must not remove the proxy before
            // the root-style landing animation has visibly completed.
            let elapsed = CACurrentMediaTime() - landingStartMediaTime
            let remaining = max(0, landingDuration - elapsed)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }

            folderReorderCommit.markVisualsFinished(context)
            guard folderReorderCommit.consumeIfReady(context) else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layoutDocument = committedDocument
            invalidatePageSurfaceCache()
            if !adoptCommittedFolderReorder(context) {
                context.sourceEntry.tileLayer.removeFromSuperlayer()
                folderHiddenApplicationID = nil
                if openFolderID == context.folderID {
                    renderFolderOverlay(animated: false)
                } else {
                    needsLayout = true
                    layoutSubtreeIfNeeded()
                }
                retireFolderTrackingButtonAfterPointerCallback(context.trackingButton)
            }
            // The destination owns the full-resolution artwork before
            // its proxy disappears, without implicit layer cross-fades.
            context.proxyLayer.removeAllAnimations()
            context.proxyLayer.removeFromSuperlayer()
            CATransaction.commit()
        } catch {
            folderReorderCommit.finishImmediately(context)
            guard folderReorderCommit.consumeIfReady(context) else { return }
            _ = dragInteraction.beginRollback()
            layoutDocument = draft.snapshot
            folderPaging.selectPage(context.sourcePage)
            NSSound.beep()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            folderHiddenApplicationID = nil
            if openFolderID == context.folderID {
                renderFolderOverlay(animated: false)
            } else {
                needsLayout = true
                layoutSubtreeIfNeeded()
            }
            context.proxyLayer.removeAllAnimations()
            context.proxyLayer.removeFromSuperlayer()
            CATransaction.commit()
            retireFolderTrackingButtonAfterPointerCallback(context.trackingButton)
        }
        isCommittingLayout = false
        dragInteraction.finish()
    }

}
