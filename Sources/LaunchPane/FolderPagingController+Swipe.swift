import AppKit
import QuartzCore

extension FolderPagingController {
    func beginSwipe(_ swipe: InteractiveFolderPageSwipe, in viewportLayer: CALayer) {
        let outgoingSurface = swipe.outgoingSurface
        let incomingSurface = swipe.incomingSurface
        let resting = swipe.restingPosition
        let direction = swipe.direction
        let width = swipe.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoingSurface.layer.removeAllAnimations()
        incomingSurface.layer.removeAllAnimations()
        outgoingSurface.layer.position = resting
        incomingSurface.layer.position = CGPoint(x: resting.x + CGFloat(direction) * width, y: resting.y)
        outgoingSurface.layer.opacity = 1
        incomingSurface.layer.opacity = 1
        outgoingSurface.layer.isHidden = false
        incomingSurface.layer.isHidden = false
        if incomingSurface.layer.superlayer == nil { viewportLayer.addSublayer(incomingSurface.layer) }
        CATransaction.commit()

        invalidateSwipe()
        self.swipe = swipe
    }

    func presentSwipe(_ swipe: InteractiveFolderPageSwipe) {
        guard self.swipe === swipe, swipe.phase == .tracking else { return }
        swipe.needsPresentationUpdate = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swipe.outgoingSurface.layer.position = CGPoint(
            x: swipe.restingPosition.x + swipe.translation, y: swipe.restingPosition.y)
        swipe.incomingSurface.layer.position = CGPoint(
            x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width + swipe.translation,
            y: swipe.restingPosition.y)
        CATransaction.commit()
    }

    func updateSwipe(
        _ swipe: InteractiveFolderPageSwipe, deltaX: CGFloat, timestamp: TimeInterval
    ) {
        guard self.swipe === swipe, swipe.phase == .tracking else { return }
        let elapsed = min(1.0 / 24.0, max(1.0 / 240.0, timestamp - swipe.lastTimestamp))
        swipe.lastTimestamp = timestamp

        let trackingGain: CGFloat = 1.60
        let adjustedDelta = deltaX * trackingGain
        let maximumDelta = swipe.width * 0.18
        let boundedDelta = min(maximumDelta, max(-maximumDelta, adjustedDelta))
        let instantaneousVelocity = boundedDelta / elapsed
        let maximumVelocity = swipe.width * 8.0
        let boundedVelocity = min(maximumVelocity, max(-maximumVelocity, instantaneousVelocity))
        let velocityTimeConstant = 0.034
        let velocityAlpha = 1 - exp(-Double(elapsed) / velocityTimeConstant)
        swipe.velocity += (boundedVelocity - swipe.velocity) * CGFloat(velocityAlpha)

        let proposed = swipe.translation + boundedDelta
        if swipe.direction > 0 {
            swipe.translation = min(0, max(-swipe.width, proposed))
        } else {
            swipe.translation = max(0, min(swipe.width, proposed))
        }
        swipe.needsPresentationUpdate = true
    }

    @discardableResult func completeSwipe(_ swipe: InteractiveFolderPageSwipe, commit: Bool) -> Bool {
        guard self.swipe === swipe else { return false }
        swipe.outgoingSurface.layer.removeAllAnimations()
        swipe.incomingSurface.layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if commit {
            swipe.incomingSurface.layer.position = swipe.restingPosition
            swipe.outgoingSurface.layer.position = CGPoint(
                x: swipe.restingPosition.x - CGFloat(swipe.direction) * swipe.width, y: swipe.restingPosition.y)
            swipe.incomingSurface.layer.isHidden = false
            swipe.outgoingSurface.layer.isHidden = true
        } else {
            swipe.outgoingSurface.layer.position = swipe.restingPosition
            swipe.incomingSurface.layer.position = CGPoint(
                x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width, y: swipe.restingPosition.y)
            swipe.outgoingSurface.layer.isHidden = false
            swipe.incomingSurface.layer.isHidden = true
        }
        CATransaction.commit()

        if commit {
            selectPage(swipe.targetPage, selectedIndex: -1)
            contentLayer = swipe.incomingSurface.layer
        }
        self.swipe = nil
        return true
    }

    func settleSwipe(commit: Bool, completion: @escaping @MainActor (InteractiveFolderPageSwipe) -> Void) {
        guard let swipe = self.swipe, swipe.phase == .tracking else { return }
        if swipe.needsPresentationUpdate { presentSwipe(swipe) }

        swipe.phase = .settling
        invalidateSwipe()
        let animationGeneration = generation

        let finalTranslation = commit ? -CGFloat(swipe.direction) * swipe.width : 0
        let outgoingStart = swipe.outgoingSurface.layer.presentation()?.position ?? swipe.outgoingSurface.layer.position
        let incomingStart = swipe.incomingSurface.layer.presentation()?.position ?? swipe.incomingSurface.layer.position
        let outgoingEnd = CGPoint(x: swipe.restingPosition.x + finalTranslation, y: swipe.restingPosition.y)
        let incomingEnd = CGPoint(
            x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width + finalTranslation,
            y: swipe.restingPosition.y)

        guard
            let transition = LaunchpadVisualStyle.interactivePageSettleTransition(
                direction: swipe.direction, displayWidth: swipe.width, releaseVelocity: swipe.velocity,
                targetDelta: outgoingEnd.x - outgoingStart.x)
        else {
            completion(swipe)
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

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, animationGeneration == self.generation,
                    self.swipe === swipe
                else { return }
                completion(swipe)
            }
        }
        swipe.outgoingSurface.layer.position = outgoingEnd
        swipe.incomingSurface.layer.position = incomingEnd
        swipe.outgoingSurface.layer.add(
            animation(from: outgoingStart, to: outgoingEnd), forKey: "interactiveFolderPageOut")
        swipe.incomingSurface.layer.add(
            animation(from: incomingStart, to: incomingEnd), forKey: "interactiveFolderPageIn")
        CATransaction.commit()
    }
}
