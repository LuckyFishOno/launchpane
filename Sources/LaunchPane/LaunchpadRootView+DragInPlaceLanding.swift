import AppCore
import AppKit
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    struct InPlaceDragLanding {
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        let revealsSource: Bool
    }

    func restoreInPlaceDragTiles(
        _ session: LaunchpadDragSession, shouldAnimate: Bool, animation: DragLandingAnimation
    ) {
        let surface = session.originalSurface
        let sourceID = session.sourceEntry.item.id
        let duration = animation.duration
        let completionTransition = animation.transition
        // --------------------------------------------
        // Cancel / rollback:
        //
        // 所有 App 都直接在同一棵 surface
        // 裡回到原始位置。
        //
        // 沒有 previewSurface -> originalSurface
        // handoff。
        // --------------------------------------------

        CATransaction.begin()

        CATransaction.setDisableActions(true)

        for entry in surface.entries {
            guard let originalFrame = session.originalFramesByIdentifier[entry.item.id] else { continue }

            let visiblePosition = entry.tileLayer.presentation()?.position ?? entry.tileLayer.position

            entry.tileLayer.removeAnimation(forKey: "dragReflowPosition")

            entry.tileLayer.removeAnimation(forKey: "dragRollbackPosition")

            entry.tileLayer.removeAnimation(forKey: "dragReflowOpacity")

            entry.frames = originalFrame

            entry.absoluteIndex = session.originalIndexByIdentifier[entry.item.id] ?? entry.absoluteIndex

            entry.tileLayer.position = originalFrame.cell.center

            entry.tileLayer.opacity = 1

            if entry.item.id == sourceID {
                entry.tileLayer.removeFromSuperlayer()

                continue
            }

            entry.button.frame = originalFrame.icon

            guard shouldAnimate, visiblePosition != originalFrame.cell.center else { continue }

            let rollback = CABasicAnimation(keyPath: "position")

            rollback.fromValue = NSValue(point: visiblePosition)

            rollback.toValue = NSValue(point: originalFrame.cell.center)

            rollback.duration = duration

            rollback.timingFunction = completionTransition.timingFunction

            entry.tileLayer.add(rollback, forKey: "dragRollbackPosition")
        }

        CATransaction.commit()
    }

    func inPlaceDragLanding(_ session: LaunchpadDragSession, committed: Bool) -> InPlaceDragLanding {
        let surface = session.originalSurface
        let proxy = session.proxyLayer
        let sourceID = session.sourceEntry.item.id
        let destination: CGPoint

        let destinationScale: CGFloat

        let destinationOpacity: Float

        let shouldRevealSource: Bool

        if committed {
            switch session.target {
            case .insertion, .pageInsertion:
                destination =
                    surface.entries.first { $0.item.id == sourceID }?.frames.cell.center
                    ?? session.sourceEntry.frames.cell.center

                destinationScale = 1
                destinationOpacity = 1
                shouldRevealSource = true

            case .application, .folder:
                destination = mergeLandingDestination(in: surface, session: session) ?? proxy.position

                destinationScale = mergeLandingScale(session: session)
                destinationOpacity = 0
                shouldRevealSource = false

            case .outside:
                destination =
                    session.originalFramesByIdentifier[sourceID]?.cell.center ?? session.sourceEntry.frames.cell.center

                destinationScale = 1
                destinationOpacity = 1
                shouldRevealSource = true
            }
        } else {
            destination =
                session.originalFramesByIdentifier[sourceID]?.cell.center ?? session.sourceEntry.frames.cell.center

            destinationScale = 1
            destinationOpacity = 1
            shouldRevealSource = true

        }

        return InPlaceDragLanding(
            position: destination, scale: destinationScale, opacity: destinationOpacity,
            revealsSource: shouldRevealSource)
    }

    func finishInPlaceDragVisuals(
        _ session: LaunchpadDragSession, committed: Bool, animated: Bool, completion: (() -> Void)?
    ) {
        updateDropHighlight(.outside)

        let surface = session.originalSurface

        let proxy = session.proxyLayer

        let sourceID = session.sourceEntry.item.id

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let animation = dragLandingAnimation(session, committed: committed, shouldAnimate: shouldAnimate)

        let landing = inPlaceDragLanding(session, committed: committed)
        let shouldRevealSource = landing.revealsSource
        if !committed { restoreInPlaceDragTiles(session, shouldAnimate: shouldAnimate, animation: animation) }

        // Live source tile 不保留 mouseDown 狀態。
        CATransaction.begin()

        CATransaction.setDisableActions(true)

        surface.layer.opacity = 1

        surface.layer.isHidden = false

        session.sourceEntry.iconLayer.removeAnimation(forKey: "iconPressedOpacity")

        session.sourceEntry.iconLayer.opacity = 1

        session.sourceEntry.iconLayer.setAffineTransform(.identity)

        session.sourceEntry.tileLayer.opacity = 1

        CATransaction.commit()

        activeSurface = surface

        pageContentLayer = surface.layer

        let finalize: @MainActor () -> Void = { [weak proxy, weak sourceLayer = session.sourceEntry.tileLayer] in

            CATransaction.begin()

            CATransaction.setDisableActions(true)

            proxy?.opacity = 0
            DragVisualCoordinator.retire(proxy)

            if shouldRevealSource, let sourceLayer {
                sourceLayer.removeAllAnimations()

                sourceLayer.opacity = 1

                if sourceLayer.superlayer == nil {
                    // Proxy 已經先移除，
                    // 然後 live source 接手。
                    //
                    // 同一個 transaction，
                    // 不存在兩個 visual owner。
                    surface.layer.addSublayer(sourceLayer)
                }
            }

            // source NSButton 在 mouse tracking
            // 結束後才移到最後位置。
            if let frame = committed
                ? surface.entries.first(where: { $0.item.id == sourceID })?.frames
                : session.originalFramesByIdentifier[sourceID] {
                session.sourceEntry.button.frame = frame.icon
            }

            CATransaction.commit()

            completion?()
        }

        animateInPlaceLanding(
            proxy, landing: landing, animation: animation, shouldAnimate: shouldAnimate, finalize: finalize)
    }

    func animateInPlaceLanding(
        _ proxy: CALayer, landing: InPlaceDragLanding, animation: DragLandingAnimation, shouldAnimate: Bool,
        finalize: @escaping @MainActor () -> Void
    ) {
        let destination = landing.position
        let destinationScale = landing.scale
        let destinationOpacity = landing.opacity
        let completionKind = animation.kind
        let completionTransition = animation.transition
        let duration = animation.duration
        guard shouldAnimate else {
            CATransaction.begin()

            CATransaction.setDisableActions(true)

            proxy.position = destination

            proxy.setAffineTransform(.init(scaleX: destinationScale, y: destinationScale))

            proxy.opacity = destinationOpacity

            CATransaction.commit()

            finalize()

            return
        }

        if completionKind == .merge {
            DragProxyPresentation.animateMergeProxyIntoFolder(
                proxy, destination: destination, destinationScale: destinationScale, duration: duration,
                timingFunction: completionTransition.timingFunction)

            dragVisuals.schedule(for: proxy, after: duration, completion: finalize)
            return
        }

        CATransaction.begin()

        CATransaction.setAnimationDuration(duration)

        CATransaction.setAnimationTimingFunction(completionTransition.timingFunction)

        proxy.position = destination

        proxy.setAffineTransform(.init(scaleX: destinationScale, y: destinationScale))

        proxy.opacity = destinationOpacity

        CATransaction.commit()

        dragVisuals.schedule(for: proxy, after: duration, completion: finalize)
    }
}
