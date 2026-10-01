import AppCore
import AppKit
import QuartzCore

extension LaunchpadRootView {
    func persistDragCommit(_ commitContext: LaunchpadDragCommitContext, draft: LauncherLayoutDraft) async {
        let committingSession = commitContext.session
        do {
            layoutDocument = try await layoutStore.commit(draft)
            selectedIndex = -1
            if let metrics = currentMetrics {
                currentPage = min(currentPage, pageProjection(metrics: metrics).pageCount - 1)

                if let previewSurface = committingSession.previewSurface {
                    refreshCommittedPageCacheForCrossPageMergeIfNeeded(
                        committingSession, keeping: previewSurface, metrics: metrics)
                }
            }
            if adoptCommittedPreviewIfPossible(committingSession) {
                commitContext.didAdoptCommittedPreview = true
            } else {
                invalidatePageSurfaceCache()
            }

            dragCommit.markPersistenceFinished(commitContext)
        } catch {
            _ = dragInteraction.beginRollback()
            if committingSession.folderCreationPreview != nil { closeFolder(animated: false) }
            committingSession.draft.rollback()
            layoutDocument = committingSession.draft.snapshot
            restoreSnapshotUI(afterFailedCommit: committingSession)
            invalidatePageSurfaceCache()
            NSSound.beep()
            // Restoring the original surface also terminates the visual
            // landing, so a stale Core Animation completion must not keep
            // the interaction locked.
            dragCommit.finishImmediately(commitContext)
        }
        finishDragCommitIfReady(commitContext)
    }

    func finishDragCommitIfReady(_ context: LaunchpadDragCommitContext) {
        guard dragCommit.consumeIfReady(context) else { return }

        // Keep isCommittingLayout=true until visual ownership AND AppKit hit
        // targets are ready. Unlocking here used to expose a visible tile with no
        // button for one run-loop turn; clicking it fell through to root mouseDown
        // and dismissed Launchpad.

        // When a drag preview has already been proven identical to the committed
        // document, keep that exact layer tree alive. Rebuilding it would flash
        // displaced apps at their final positions after a folder merge.
        if context.didAdoptCommittedPreview, let previewSurface = context.session.previewSurface {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            previewSurface.layer.opacity = openFolderID == nil ? 1 : 0

            previewSurface.layer.isHidden = false

            // Collapse every drag-only presentation state back to its model
            // value before pointer interaction becomes available again.
            for entry in previewSurface.entries {
                entry.tileLayer.removeAnimation(forKey: "dragReflowPosition")

                entry.tileLayer.removeAnimation(forKey: "dragReflowOpacity")

                entry.tileLayer.removeAnimation(forKey: "dragRollbackPosition")

                entry.tileLayer.opacity = 1

                entry.iconLayer.removeAnimation(forKey: "iconPressedOpacity")

                entry.iconLayer.opacity = 1

                entry.iconLayer.setAffineTransform(.identity)
            }

            CATransaction.commit()

            activeSurface = previewSurface

            pageContentLayer = previewSurface.layer

            attachButtons(to: previewSurface, hidden: openFolderID != nil)

            // Keep root AppKit ownership disabled while the Folder overlay is
            // open. closeFolder() will restore both root visibility and hit
            // targets through the normal Folder-close handoff.
            setFolderBackgroundVisible(openFolderID != nil, animated: false)
            setPageHitTargetsEnabled(openFolderID == nil)

            updateSelectionAppearance()

            if let metrics = currentMetrics {
                scheduleIconPrewarming(metrics: metrics, scale: window?.backingScaleFactor ?? 1)
            }

            // Preview layer + NSButtons are now atomically ready for input.
            isCommittingLayout = false
            retireFolderExtractionPointerOwnerAfterCommit(context.session)
            dragInteraction.finish()
            return
        }

        // Any preview that still cannot be proven identical to the committed
        // document falls back to a full rebuild. Cross-page folder merges are
        // normally adopted after their hidden page cache is refreshed above.
        //
        // IMPORTANT: perform that rebuild synchronously before unlocking input.
        // Otherwise the CALayer remains visible for a frame while its NSButton
        // has already been detached, and a folder click becomes a background click.
        needsLayout = true
        isCommittingLayout = false
        layoutSubtreeIfNeeded()

        // Full-rebuild fallback follows the same ownership invariant as the
        // adopted-preview path. A still-open Folder keeps the rebuilt root
        // surface and its hit targets hidden.
        setFolderBackgroundVisible(openFolderID != nil, animated: false)
        setPageHitTargetsEnabled(openFolderID == nil)
        retireFolderExtractionPointerOwnerAfterCommit(context.session)
        dragInteraction.finish()
    }

    func restoreSnapshotUI(afterFailedCommit session: LaunchpadDragSession) {
        currentPage = session.sourcePage
        session.originalSurface.layer.frame = bounds
        session.originalSurface.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Immutable source geometry also matters after crossing pages.
        do {
            CATransaction.begin()

            CATransaction.setDisableActions(true)

            for entry in session.originalSurface.entries {
                guard let originalFrame = session.originalFramesByIdentifier[entry.item.id] else { continue }

                entry.tileLayer.removeAllAnimations()

                entry.iconLayer.removeAllAnimations()

                entry.frames = originalFrame

                entry.absoluteIndex = session.originalIndexByIdentifier[entry.item.id] ?? entry.absoluteIndex

                entry.button.frame = originalFrame.icon

                entry.tileLayer.position = originalFrame.cell.center

                entry.tileLayer.opacity = 1

                entry.iconLayer.opacity = 1

                entry.iconLayer.setAffineTransform(.identity)
            }

            session.originalSurface.layer.opacity = 1

            session.originalSurface.layer.isHidden = false

            CATransaction.commit()
        }

        if let previewSurface = session.previewSurface {
            detachButtons(from: previewSurface)
            previewSurface.layer.removeFromSuperlayer()
        }

        session.proxyLayer.removeAllAnimations()
        session.proxyLayer.removeFromSuperlayer()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.originalSurface.layer.opacity = 1
        if session.sourceOrigin.folderID == nil, session.sourceEntry.tileLayer.superlayer == nil {
            session.originalSurface.layer.addSublayer(session.sourceEntry.tileLayer)
        }
        session.sourceEntry.tileLayer.opacity = 1
        session.sourceEntry.iconLayer.opacity = 1
        if session.sourceOrigin.folderID != nil { session.sourceEntry.button.removeFromSuperview() }
        if session.originalSurface.layer.superlayer == nil {
            rootLayer.insertSublayer(session.originalSurface.layer, below: fixedOverlayLayer)
        }
        CATransaction.commit()

        activeSurface = session.originalSurface
        pageContentLayer = session.originalSurface.layer
        attachButtons(to: session.originalSurface, hidden: false)
    }
}
