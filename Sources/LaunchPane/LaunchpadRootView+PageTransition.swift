import AppCore
import AppKit
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    func finishInteractivePageSwipe(commit: Bool) {
        guard let swipe = interactivePageSwipe, swipe.phase == .tracking else { return }

        // Make the last input sample available to Core Animation before the
        // compositor-driven settle begins.
        if swipe.needsPresentationUpdate { presentInteractivePageSwipe(swipe) }

        pagingDisplayLink?.isPaused = true
        swipe.phase = .settling
        interactivePageGeneration &+= 1
        let generation = interactivePageGeneration

        let finalTranslation = commit ? -CGFloat(swipe.direction) * swipe.width : 0
        let outgoingStart = swipe.outgoingSurface.layer.presentation()?.position ?? swipe.outgoingSurface.layer.position
        let incomingStart = swipe.incomingSurface.layer.presentation()?.position ?? swipe.incomingSurface.layer.position
        let outgoingEnd = CGPoint(x: swipe.restingPosition.x + finalTranslation, y: swipe.restingPosition.y)
        let incomingEnd = CGPoint(
            x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width + finalTranslation,
            y: swipe.restingPosition.y)

        // Use the position actually displayed, not a potentially newer input
        // sample. One cubic preserves release velocity all the way into rest;
        // stretching its duration afterward would introduce a sudden slowdown.
        guard
            let transition = LaunchpadVisualStyle.interactivePageSettleTransition(
                direction: swipe.direction, displayWidth: swipe.width, releaseVelocity: swipe.velocity,
                targetDelta: outgoingEnd.x - outgoingStart.x)
        else {
            completeInteractivePageSwipe(swipe, commit: commit)
            return
        }

        func animation(from start: CGPoint, to end: CGPoint) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: "position")
            animation.fromValue = NSValue(point: start)
            animation.toValue = NSValue(point: end)
            animation.duration = transition.duration
            animation.timingFunction = transition.timingFunction
            return animation
        }

        // Commit model endpoints and both animations together. No intermediate
        // transaction may expose the destination before its animation exists.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == interactivePageGeneration, interactivePageSwipe === swipe else { return }
                completeInteractivePageSwipe(swipe, commit: commit)
            }
        }
        swipe.outgoingSurface.layer.position = outgoingEnd
        swipe.incomingSurface.layer.position = incomingEnd
        swipe.outgoingSurface.layer.add(animation(from: outgoingStart, to: outgoingEnd), forKey: "interactivePageOut")
        swipe.incomingSurface.layer.add(animation(from: incomingStart, to: incomingEnd), forKey: "interactivePageIn")
        CATransaction.commit()
    }

    private func completeInteractivePageSwipe(_ swipe: InteractivePageSwipe, commit: Bool) {
        pagingDisplayLink?.isPaused = true

        swipe.outgoingSurface.layer.removeAllAnimations()
        swipe.incomingSurface.layer.removeAllAnimations()

        let scale = window?.backingScaleFactor ?? 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if commit {
            swipe.incomingSurface.layer.position = swipe.restingPosition
            swipe.outgoingSurface.layer.position = CGPoint(
                x: swipe.restingPosition.x - CGFloat(swipe.direction) * swipe.width, y: swipe.restingPosition.y)
        } else {
            swipe.outgoingSurface.layer.position = swipe.restingPosition
            swipe.incomingSurface.layer.position = CGPoint(
                x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width, y: swipe.restingPosition.y)
        }

        CATransaction.commit()

        if commit {
            // The outgoing page remains staged as CALayers only. Detaching its
            // hit targets removes its NSTrackingAreas from AppKit bookkeeping.
            detachButtons(from: swipe.outgoingSurface)

            pageContentLayer = swipe.incomingSurface.layer
            activeSurface = swipe.incomingSurface
            currentPage = swipe.targetPage
            selectedIndex = -1

            attachButtons(to: swipe.incomingSurface, hidden: false)
        } else {
            // Cancelled incoming pages never need pointer hit targets.
            detachButtons(from: swipe.incomingSurface)
            attachButtons(to: swipe.outgoingSurface, hidden: false)
        }

        interactivePageSwipe = nil
        setPageHitTargetsEnabled(true)
        updateSelectionAppearance()

        if let metrics = currentMetrics {
            let pageCount = pageProjection(metrics: metrics).pageCount
            updatePageIndicator(pageCount: pageCount, metrics: metrics, scale: scale)

            // Visible motion is already complete; topology maintenance cannot
            // steal time from the settle animation anymore.
            stageAdjacentPageSurfaces(scale: scale)
            scheduleIconPrewarming(metrics: metrics, scale: scale)
        }
    }

    func cancelInteractivePageSwipeImmediately() {
        guard let swipe = interactivePageSwipe else { return }

        pagingDisplayLink?.isPaused = true
        interactivePageGeneration &+= 1
        swipe.outgoingSurface.layer.removeAllAnimations()
        swipe.incomingSurface.layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swipe.outgoingSurface.layer.position = swipe.restingPosition
        swipe.incomingSurface.layer.position = CGPoint(
            x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width, y: swipe.restingPosition.y)
        CATransaction.commit()

        interactivePageSwipe = nil
        detachButtons(from: swipe.incomingSurface)
        attachButtons(to: swipe.outgoingSurface, hidden: false)
        setPageHitTargetsEnabled(true)

        stageAdjacentPageSurfaces(scale: window?.backingScaleFactor ?? 1)
    }

    func resetPageTransition() {
        cancelIconPrewarming()
        cancelInteractivePageSwipeImmediately()
        pageSwipeInputGate = PageSwipeInputGate()
        pendingPageDirection = 0
        pageTransitionAnimator.reset(contentLayer: pageContentLayer, canvasBounds: bounds)
        setPageHitTargetsEnabled(true)
    }

    func setPageHitTargetsEnabled(
        _ enabled: Bool, preserving preservedButton: PointerTrackingTileButton? = nil
    ) {
        guard let activeSurface else { return }
        for entry in activeSurface.entries {
            if let preservedButton, entry.button === preservedButton {
                // A live drag must keep the original NSButton attached until
                // AppKit delivers mouseUp/cancel. The button is transparent, so
                // keeping it alive does not create a second visible icon.
                entry.button.isEnabled = true
                entry.button.isHidden = false
                continue
            }
            entry.button.isEnabled = enabled
            entry.button.isHidden = !enabled || openFolderID != nil
        }
    }
}
