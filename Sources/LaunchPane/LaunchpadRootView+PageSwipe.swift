import AppCore
import AppKit
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    func beginPageTransition(
        from outgoingLayer: CALayer, to incomingLayer: CALayer, direction: Int,
        style: LaunchpadVisualStyle.PageTransition
    ) {
        cancelIconPrewarming()
        setPageHitTargetsEnabled(false)

        let request = PageTransitionAnimator.Request(
            outgoingLayer: outgoingLayer, incomingLayer: incomingLayer, direction: direction, style: style,
            canvasBounds: bounds)
        pageTransitionAnimator.start(request) { [weak self] queuedDirection in
            guard let self else { return }

            if let activeSurface { attachButtons(to: activeSurface, hidden: false) }
            setPageHitTargetsEnabled(true)

            if queuedDirection != 0 {
                changePage(by: queuedDirection)
                render()
                return
            }

            if let metrics = currentMetrics {
                let scale = window?.backingScaleFactor ?? 1
                stageAdjacentPageSurfaces(scale: scale)
                scheduleIconPrewarming(metrics: metrics, scale: scale)
            }
        }
    }

    func configurePagingDisplayLink() {
        pagingDisplayLink?.invalidate()

        // NSView.displayLink(...) follows the physical display containing this
        // view. Keep the default frame-rate range so Core Animation can use the
        // display's native cadence: typically 60 Hz, or up to 120 Hz on
        // ProMotion displays.
        let link = displayLink(target: self, selector: #selector(pagingDisplayLinkDidFire(_:)))

        link.isPaused = true
        link.add(to: RunLoop.main, forMode: .common)

        pagingDisplayLink = link
    }

    @objc private func pagingDisplayLinkDidFire(_ link: CADisplayLink) {
        // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
        // Folder and root direct-manipulation share one display link. Only one
        // can exist at a time; presenting at most once per refresh prevents a
        // burst of trackpad events from turning into redundant CA commits.
        if let folderSwipe = folderPaging.swipe, folderSwipe.phase == .tracking,
            folderSwipe.needsPresentationUpdate {
            presentInteractiveFolderPageSwipe(folderSwipe)
            return
        }

        guard !link.isPaused, let swipe = interactivePageSwipe, swipe.phase == .tracking, swipe.needsPresentationUpdate
        else { return }

        presentInteractivePageSwipe(swipe)
    }

    func presentInteractivePageSwipe(_ swipe: InteractivePageSwipe) {
        guard swipe.phase == .tracking else { return }

        swipe.needsPresentationUpdate = false

        let outgoingPosition = CGPoint(x: swipe.restingPosition.x + swipe.translation, y: swipe.restingPosition.y)

        let incomingPosition = CGPoint(
            x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width + swipe.translation,
            y: swipe.restingPosition.y)

        // One compositor transaction per physical display refresh.
        //
        // Trackpad events may arrive faster, slower, or irregularly relative
        // to refresh. Coalescing them here avoids presenting multiple model
        // updates between two visible frames.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        swipe.outgoingSurface.layer.position = outgoingPosition
        swipe.incomingSurface.layer.position = incomingPosition

        CATransaction.commit()
    }

    func handleInteractivePageSwipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty else { return false }

        let disposition = InteractivePageSwipeDecision.disposition(
            hasActiveSwipe: interactivePageSwipe != nil, phase: PageScrollPhase(event.phase),
            hasHorizontalMovement: event.scrollingDeltaX != 0,
            isHorizontalDominant: abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

        switch disposition {
        case .useDiscretePaging:
            if interactivePageSwipe != nil { cancelInteractivePageSwipeImmediately() }
            return false
        case .cancel:
            finishInteractivePageSwipe(commit: false)
            return true
        case .finish: return finishInteractivePageSwipeAfterRelease()
        case .beginOrUpdate: return continueInteractivePageSwipe(event)
        }
    }

    private func finishInteractivePageSwipeAfterRelease() -> Bool {
        guard let swipe = interactivePageSwipe else { return false }
        guard swipe.phase == .tracking else { return true }
        let width = max(1, swipe.width)

        let progress = min(1, max(0, -swipe.translation * CGFloat(swipe.direction) / width))
        let forwardVelocity = -swipe.velocity * CGFloat(swipe.direction)
        let normalizedForwardVelocity = forwardVelocity / width
        // A native-feeling trackpad flick should not require dragging a large
        // fraction of the screen. Project the release briefly forward and allow
        // a short, intentional flick to commit while still rejecting tiny jitter.
        let projectedProgress = progress + normalizedForwardVelocity * 0.10

        // Launchpad paging should react to intent, not require a long drag.
        //
        // A short deliberate horizontal movement is enough to commit:
        // - ~2.5% page travel commits even at a gentle release.
        // - A very short flick can commit from ~0.8% when it has velocity.
        //
        // Horizontal-dominance filtering and the one-page-per-gesture gate
        // still protect against ordinary trackpad jitter.
        let commit =
            progress >= 0.025 || (progress >= 0.012 && projectedProgress >= 0.040)
            || (progress >= 0.008 && normalizedForwardVelocity >= 0.25)

        finishInteractivePageSwipe(commit: commit)
        return true
    }

    private func continueInteractivePageSwipe(_ event: NSEvent) -> Bool {
        guard interactivePageSwipe?.phase != .settling else { return true }
        // Native paging ignores inertial scrolling after the finger releases.
        if !event.momentumPhase.isEmpty { return true }

        if event.phase.contains(.began) { cancelInteractivePageSwipeImmediately() }

        if interactivePageSwipe == nil {
            let direction = event.scrollingDeltaX < 0 ? 1 : -1

            let didBegin = beginInteractivePageSwipe(direction: direction, timestamp: event.timestamp)
            if didBegin {
                // Do not let partial vertical accumulation from an earlier event
                // leak into the discrete gesture that follows this swipe.
                pageScrollGesture = PageScrollGesture()
            }
        }

        if let swipe = interactivePageSwipe, event.scrollingDeltaX != 0 {
            updateInteractivePageSwipe(swipe, deltaX: event.scrollingDeltaX, timestamp: event.timestamp)
        }

        return true
    }

    @discardableResult private func beginInteractivePageSwipe(direction: Int, timestamp: TimeInterval) -> Bool {
        guard !pageTransitionAnimator.isAnimating, interactivePageSwipe == nil, let metrics = currentMetrics,
            let outgoingSurface = activeSurface
        else { return false }

        let pageCount = pageProjection(metrics: metrics).pageCount
        let targetPage = currentPage + direction
        guard (0..<pageCount).contains(targetPage), let incomingSurface = pageSurfaces[targetPage] else { return false }

        cancelIconPrewarming()
        setPageHitTargetsEnabled(false)

        let scale = window?.backingScaleFactor ?? 1
        let restingPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        let width = max(1, bounds.width)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        outgoingSurface.layer.removeAllAnimations()
        incomingSurface.layer.removeAllAnimations()

        outgoingSurface.layer.frame = bounds
        outgoingSurface.layer.contentsScale = scale
        outgoingSurface.layer.position = restingPosition
        outgoingSurface.layer.opacity = 1
        outgoingSurface.layer.isHidden = false

        incomingSurface.layer.frame = bounds
        incomingSurface.layer.contentsScale = scale
        incomingSurface.layer.position = CGPoint(
            x: restingPosition.x + CGFloat(direction) * width, y: restingPosition.y)
        incomingSurface.layer.opacity = 1
        incomingSurface.layer.isHidden = false

        if incomingSurface.layer.superlayer == nil {
            rootLayer.insertSublayer(incomingSurface.layer, below: fixedOverlayLayer)
        }

        CATransaction.commit()

        // The incoming page needs only its CALayer during the gesture.
        // Its NSButton/NSTrackingArea hit targets are attached only if this page
        // becomes current after settle completes. This keeps gesture begin free
        // of NSView hierarchy churn and keeps long-session view count bounded.

        interactivePageGeneration &+= 1
        interactivePageSwipe = InteractivePageSwipe(
            outgoingSurface: outgoingSurface, incomingSurface: incomingSurface, targetPage: targetPage,
            direction: direction, restingPosition: restingPosition, width: width, timestamp: timestamp)
        return true
    }

    private func updateInteractivePageSwipe(
        _ swipe: InteractivePageSwipe, deltaX: CGFloat, timestamp: TimeInterval) {
        guard swipe.phase == .tracking else { return }
        let rawElapsed = timestamp - swipe.lastTimestamp
        let elapsed = min(1.0 / 24.0, max(1.0 / 240.0, rawElapsed))
        swipe.lastTimestamp = timestamp

        // Protect against a rare huge NSEvent delta without adding any filter or
        // latency to ordinary trackpad movement.
        // AppKit's precise trackpad delta is deliberately conservative for a
        // full-screen page. A modest gain keeps the page visually attached to
        // a light two-finger swipe without turning the gesture into a jump.
        let trackingGain: CGFloat = 1.60
        let adjustedDelta = deltaX * trackingGain
        let maximumDelta = swipe.width * 0.18
        let boundedDelta = min(maximumDelta, max(-maximumDelta, adjustedDelta))

        let instantaneousVelocity = boundedDelta / elapsed
        let maximumVelocity = swipe.width * 8.0
        let boundedVelocity = min(maximumVelocity, max(-maximumVelocity, instantaneousVelocity))

        // Fixed 0.72/0.28 filtering changes behaviour with event frequency.
        // A time-constant filter feels the same at 60 Hz, 120 Hz and under
        // irregular event delivery. It affects release physics only.
        let velocityTimeConstant = 0.034
        let velocityAlpha = 1 - exp(-Double(elapsed) / velocityTimeConstant)
        swipe.velocity += (boundedVelocity - swipe.velocity) * CGFloat(velocityAlpha)

        let proposed = swipe.translation + boundedDelta
        if swipe.direction > 0 {
            swipe.translation = min(0, max(-swipe.width, proposed))
        } else {
            swipe.translation = max(0, min(swipe.width, proposed))
        }

        // Keep input sampling completely finger-driven, but present the newest
        // translation only on the physical display's refresh boundary.
        //
        // Multiple trackpad events between two refreshes collapse into one
        // compositor update; on ProMotion the same path naturally gets more
        // opportunities to present.
        swipe.needsPresentationUpdate = true

        if let pagingDisplayLink {
            pagingDisplayLink.isPaused = false
        } else {
            // Defensive fallback. Normal macOS 15 presentation always has the
            // NSView display link configured.
            presentInteractivePageSwipe(swipe)
        }
    }
}
