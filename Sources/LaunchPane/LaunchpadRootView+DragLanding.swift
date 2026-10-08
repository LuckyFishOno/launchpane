import AppCore
import AppKit
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    func promoteStationaryDragLanding(
        _ session: LaunchpadDragSession, committed: Bool, landing: inout DragLanding
    ) {
        let proxy = session.proxyLayer
        if committed, session.target.isInsertion, let liveLayer = landing.revealLayer,
            let liveSurface = landing.revealSurface {
            let visibleProxyPosition = proxy.presentation()?.position ?? proxy.position

            let landingDistance = hypot(
                visibleProxyPosition.x - landing.position.x, visibleProxyPosition.y - landing.position.y)

            // Less than one logical point is visually already landed.
            // Keeping the proxy around at this point only creates a stale frame.
            if landingDistance <= 0.75 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)

                proxy.removeAllAnimations()
                proxy.removeFromSuperlayer()

                if liveLayer.superlayer == nil { liveSurface.layer.addSublayer(liveLayer) }

                liveLayer.opacity = 1

                CATransaction.commit()

                // The delayed reflow completion must not perform the source-owner
                // handoff a second time.
                landing.revealLayer = nil
                landing.revealSurface = nil
            }
        }

    }

    func finishDragVisuals(
        _ session: LaunchpadDragSession, committed: Bool, animated: Bool, completion: (() -> Void)? = nil
    ) {
        if committed, session.folderCreationPreview != nil {
            finishFolderCreationPreviewVisuals(session, animated: animated, completion: completion)
            return
        }
        // Same-page reorder uses one persistent page tree.
        // Never enter the legacy preview/original surface
        // handoff path for this gesture.
        if session.usesInPlacePreview {
            finishInPlaceDragVisuals(session, committed: committed, animated: animated, completion: completion)
            return
        }

        updateDropHighlight(.outside)

        let proxy = session.proxyLayer

        // Mouse-up ends the pressed state immediately.
        //
        // The proxy may stay alive while surrounding tiles finish their reflow,
        // but its bitmap must no longer contain the mouse-down opacity / hover
        // transform. Otherwise the stale snapshot looks like an afterimage after
        // the user has already released the icon.
        refreshDragProxyForRelease(
            proxy, sourceEntry: session.sourceEntry, hidesLabel: session.isSourceLabelHiddenForMerge)

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let animation = dragLandingAnimation(session, committed: committed, shouldAnimate: shouldAnimate)

        var landing = prepareDragLanding(session, committed: committed, shouldAnimate: shouldAnimate)
        let destination = landing.position
        let destinationScale = landing.scale
        let destinationOpacity = landing.opacity

        session.sourceEntry.iconLayer.opacity = 1

        // If mouse-up happens while the dragged tile is already sitting exactly
        // on its insertion slot, there is no source-tile landing motion left to
        // display.
        //
        // Previously the snapshot proxy was still kept alive for the full
        // full drag-reflow duration. That left a stale bitmap sitting on
        // screen after mouse-up and visually read as an afterimage.
        //
        // Promote the real preview tile immediately in that case. Other displaced
        // tiles are still allowed to finish their existing reflow animation, and
        // the normal completion path below still waits for the declared duration.
        promoteStationaryDragLanding(session, committed: committed, landing: &landing)
        let revealLayer = landing.revealLayer
        let revealSurface = landing.revealSurface

        guard shouldAnimate else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            proxy.position = destination

            proxy.setAffineTransform(.init(scaleX: destinationScale, y: destinationScale))

            proxy.opacity = destinationOpacity

            proxy.removeFromSuperlayer()

            if let revealLayer, revealLayer.superlayer == nil, let revealSurface {
                revealSurface.layer.addSublayer(revealLayer)
            }
            revealLayer?.opacity = 1

            CATransaction.commit()
            completion?()
            return
        }

        animateDragLanding(
            session, committed: committed, landing: landing, animation: animation, completion: completion)
    }

    func animateDragLanding(
        _ session: LaunchpadDragSession, committed: Bool, landing: DragLanding, animation: DragLandingAnimation,
        completion: (() -> Void)?
    ) {
        let proxy = session.proxyLayer
        let previewSurface = session.previewSurface
        let originalSurface = session.originalSurface
        let sourceID = session.sourceEntry.item.id
        let revealLayer = landing.revealLayer
        let revealSurface = landing.revealSurface
        let finishPresentation: @MainActor () -> Void = { [weak proxy, weak revealLayer] in

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            proxy?.removeFromSuperlayer()
            if !committed {
                previewSurface?.layer.removeFromSuperlayer()
                originalSurface.layer.opacity = 1
            }
            if let revealLayer, revealLayer.superlayer == nil, let revealSurface {
                revealSurface.layer.addSublayer(revealLayer)
            }
            revealLayer?.opacity = 1
            CATransaction.commit()
            completion?()
        }

        CATransaction.begin()

        CATransaction.setAnimationDuration(animation.duration)

        CATransaction.setAnimationTimingFunction(animation.transition.timingFunction)

        if !committed, let previewSurface {
            animateRollbackTiles(
                from: previewSurface, to: originalSurface, excluding: sourceID, transition: animation.transition)
        }

        if animation.kind == .merge {
            CATransaction.commit()

            DragProxyPresentation.animateMergeProxyIntoFolder(
                proxy, destination: landing.position, destinationScale: landing.scale, duration: animation.duration,
                timingFunction: animation.transition.timingFunction)
        } else {
            proxy.position = landing.position

            proxy.setAffineTransform(.init(scaleX: landing.scale, y: landing.scale))

            proxy.opacity = landing.opacity

            CATransaction.commit()
        }

        // A rollback can have displaced preview tiles still moving even when
        // the pointer has already brought the proxy back to its origin. In that
        // case the proxy creates no implicit animation, so a CATransaction
        // completion may fire before the visible rollback finishes. Drive the
        // handoff from the declared transition duration instead.
        dragVisuals.schedule(for: proxy, after: animation.visualDuration, completion: finishPresentation)
    }
}
