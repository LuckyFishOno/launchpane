import AppCore
import AppKit
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    struct DragReflowAnimation {
        let transition: LaunchpadVisualStyle.DragReflowTransition
        let enabled: Bool
        let scale: CGFloat
    }

    func updateDragPreviewLayout(
        _ session: LaunchpadDragSession, location: DragPageLocation, animated: Bool, metrics: GridMetrics
    ) {
        let previousLocation = session.previewLocation
        guard previousLocation != location,
            let document = projectedDocument(session, location: location, metrics: metrics)
        else { return }
        session.previewLocation = location
        session.projectedDocument = document
        let projection = pageProjection(metrics: metrics, document: document)
        let items = projection.items
        let range = projection.range(forPage: currentPage)
        var targetFrames: [LauncherLayoutItemIdentifier: GridItemFrames] = [:]
        var targetIndices: [LauncherLayoutItemIdentifier: Int] = [:]
        for (localIndex, item) in items[range].enumerated() {
            if let frames = metrics.itemFrames(forItemAt: localIndex) {
                targetFrames[item.id] = frames
                targetIndices[item.id] = range.lowerBound + localIndex
            }
        }
        let previousRank =
            (previousLocation?.page ?? session.sourcePage) * metrics.itemsPerPage + (previousLocation?.index ?? 0)
        let transition = LaunchpadVisualStyle.dragReflowTransition(
            movedForward: location.page * metrics.itemsPerPage + location.index > previousRank)
        let scale = window?.backingScaleFactor ?? 1
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let workingSurface: LaunchpadPageSurface = {
            if session.usesInPlacePreview { return session.originalSurface }

            if let previewSurface = session.previewSurface { return previewSurface }

            return session.originalSurface
        }()

        let workingIDs = Set(workingSurface.entries.map { $0.item.id })

        let targetIDs = Set(targetFrames.keys)

        let animation = DragReflowAnimation(transition: transition, enabled: shouldAnimate, scale: scale)
        if workingIDs == targetIDs {
            reflowExistingDragSurface(
                session, surface: workingSurface, targetFrames: targetFrames, targetIndices: targetIndices,
                animation: animation)
            return
        }
        let newSurface = makePageSurface(
            pageIndex: currentPage, items: items, metrics: metrics, scale: scale, projection: projection)
        replaceDragPreviewSurface(
            session, previousSurface: workingSurface, newSurface: newSurface, animation: animation)
    }

    func reflowExistingDragSurface(
        _ session: LaunchpadDragSession, surface workingSurface: LaunchpadPageSurface,
        targetFrames: [LauncherLayoutItemIdentifier: GridItemFrames],
        targetIndices: [LauncherLayoutItemIdentifier: Int], animation: DragReflowAnimation
    ) {
        let transition = animation.transition
        let shouldAnimate = animation.enabled
        if session.previewSurface == nil {
            session.usesInPlacePreview = true

            activeSurface = session.originalSurface

            pageContentLayer = session.originalSurface.layer
        }

        CATransaction.begin()

        CATransaction.setDisableActions(true)

        // One wall-clock start for the complete reflow batch. Every displaced
        // tile converts this exact media time into its own layer time.
        let reflowBatchMediaTime = CACurrentMediaTime()

        workingSurface.layer.opacity = 1

        workingSurface.layer.isHidden = false

        for entry in workingSurface.entries {
            guard let targetFrame = targetFrames[entry.item.id], let targetIndex = targetIndices[entry.item.id] else {
                continue
            }

            // 取真正螢幕上目前的位置。
            //
            // 如果使用者很快從 A -> B -> C，
            // 新動畫直接從 presentation position
            // 接續，不跳回上一個 model position。
            let visiblePosition = entry.tileLayer.presentation()?.position ?? entry.tileLayer.position

            entry.tileLayer.removeAnimation(forKey: "dragReflowPosition")

            entry.tileLayer.removeAnimation(forKey: "dragRollbackPosition")

            entry.tileLayer.removeAnimation(forKey: "dragReflowOpacity")

            entry.tileLayer.position = targetFrame.cell.center

            entry.tileLayer.opacity = 1

            entry.frames = targetFrame

            entry.absoluteIndex = targetIndex

            if entry.item.id == session.sourceEntry.item.id {
                // Source item 仍然只有 drag proxy
                // 是唯一 visual owner。
                //
                // source NSButton 不在 drag 中移動，
                // 避免 AppKit mouse tracking view
                // 在 mouseDown -> mouseUp 中途換 frame。
                entry.tileLayer.removeFromSuperlayer()

                continue
            }

            entry.button.frame = targetFrame.icon

            guard shouldAnimate, visiblePosition != targetFrame.cell.center else { continue }

            let move = CABasicAnimation(keyPath: "position")

            move.fromValue = NSValue(point: visiblePosition)

            move.toValue = NSValue(point: targetFrame.cell.center)

            move.duration = transition.duration

            move.timingFunction = transition.timingFunction

            move.beginTime = entry.tileLayer.convertTime(reflowBatchMediaTime, from: nil)

            entry.tileLayer.add(move, forKey: "dragReflowPosition")
        }

        CATransaction.commit()

    }

    func replaceDragPreviewSurface(
        _ session: LaunchpadDragSession, previousSurface: LaunchpadPageSurface, newSurface: LaunchpadPageSurface,
        animation: DragReflowAnimation
    ) {
        let transition = animation.transition
        var oldPositions: [LauncherLayoutItemIdentifier: CGPoint] = [:]

        for entry in previousSurface.entries {
            oldPositions[entry.item.id] = entry.tileLayer.presentation()?.position ?? entry.tileLayer.position
        }

        CATransaction.begin()

        CATransaction.setDisableActions(true)

        let fallbackReflowBatchMediaTime = CACurrentMediaTime()

        newSurface.layer.frame = bounds

        newSurface.layer.contentsScale = animation.scale

        newSurface.layer.opacity = 1

        newSurface.layer.isHidden = false

        for entry in newSurface.entries {
            let targetPosition = entry.tileLayer.position

            if entry.item.id == session.sourceEntry.item.id {
                entry.tileLayer.removeFromSuperlayer()

                continue
            }

            guard animation.enabled else { continue }

            let startPosition: CGPoint

            if let oldPosition = oldPositions[entry.item.id] {
                startPosition = oldPosition
            } else {
                startPosition = CGPoint(x: targetPosition.x + transition.enteringItemOffset, y: targetPosition.y)

                let fade = CABasicAnimation(keyPath: "opacity")

                fade.fromValue = 0
                fade.toValue = 1

                fade.duration = transition.enteringItemFadeDuration

                fade.timingFunction = transition.timingFunction

                fade.beginTime = entry.tileLayer.convertTime(fallbackReflowBatchMediaTime, from: nil)

                entry.tileLayer.add(fade, forKey: "dragReflowOpacity")
            }

            guard startPosition != targetPosition else { continue }

            let move = CABasicAnimation(keyPath: "position")

            move.fromValue = NSValue(point: startPosition)

            move.toValue = NSValue(point: targetPosition)

            move.duration = transition.duration

            move.timingFunction = transition.timingFunction

            move.beginTime = entry.tileLayer.convertTime(fallbackReflowBatchMediaTime, from: nil)

            entry.tileLayer.add(move, forKey: "dragReflowPosition")
        }

        // 如果未來真的進入 fallback，
        // 舊 surface 必須先失去 render ownership。
        previousSurface.layer.removeAllAnimations()

        previousSurface.layer.opacity = 0

        previousSurface.layer.isHidden = true

        previousSurface.layer.removeFromSuperlayer()

        rootLayer.insertSublayer(newSurface.layer, below: fixedOverlayLayer)

        CATransaction.commit()

        session.previewSurface = newSurface

        session.usesInPlacePreview = false
    }

    func promoteDragPreviewSurface(_ session: LaunchpadDragSession) {
        if let previewSurface = session.previewSurface {
            // The preview becomes the sole visual owner while persistence is pending.
            // Remove the old native views before hiding/removing their backing layer so
            // transparent hit targets and accessibility elements cannot survive promotion.
            detachButtons(from: session.originalSurface)

            activeSurface = previewSurface

            pageContentLayer = previewSurface.layer

            // 原 surface 已經不需要顯示，
            // 但保留正確 model state，
            // 以防 layout commit 失敗。
            session.originalSurface.layer.removeFromSuperlayer()

            session.originalSurface.layer.opacity = 1

            session.sourceEntry.tileLayer.opacity = 1
        }
    }

    func makeDragProxy(for entry: LaunchpadPageEntry, initialPoint _: CGPoint) -> CALayer {
        DragProxyPresentation.makeDragProxy(for: entry, scale: max(1, window?.backingScaleFactor ?? 1))
    }

    func refreshDragProxyForRelease(
        _ proxy: CALayer, sourceEntry: LaunchpadPageEntry, hidesLabel: Bool = false
    ) {
        DragProxyPresentation.refreshDragProxyForRelease(
            proxy, sourceEntry: sourceEntry, scale: max(1, window?.backingScaleFactor ?? 1), hidesLabel: hidesLabel)
    }
}
