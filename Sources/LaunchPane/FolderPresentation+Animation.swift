import AppKit
import QuartzCore

extension FolderPresentation {
    func isCurrentAnimation(_ generation: Int, contentLayer: CALayer) -> Bool {
        generation == folderAnimationGeneration && folderContentAnimationLayer === contentLayer
    }

    @discardableResult func finishOpening(generation: Int, contentLayer: CALayer) -> Bool {
        guard isCurrentAnimation(generation, contentLayer: contentLayer) else { return false }
        contentLayer.removeAllAnimations()
        contentLayer.shouldRasterize = false
        contentLayer.rasterizationScale = 1
        return true
    }

    func animateOpening(
        contentLayer: CALayer, dimLayer: CALayer, transition: LaunchpadVisualStyle.FolderTransition,
        generation: Int, completion: @escaping @MainActor () -> Void
    ) {
        let dimFade = CABasicAnimation(keyPath: "opacity")
        dimFade.fromValue = 0
        dimFade.toValue = 1
        dimFade.duration = transition.openDuration * 0.82
        dimFade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = transition.sourceScale
        scaleAnimation.toValue = 1
        scaleAnimation.duration = transition.openDuration

        let contentFade = CABasicAnimation(keyPath: "opacity")
        contentFade.fromValue = 0
        contentFade.toValue = 1
        contentFade.duration = transition.openDuration

        let contentAnimation = CAAnimationGroup()
        contentAnimation.animations = [scaleAnimation, contentFade]
        contentAnimation.duration = transition.openDuration
        contentAnimation.timingFunction = transition.openTimingFunction

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentAnimation(generation, contentLayer: contentLayer) else { return }
                completion()
            }
        }
        dimLayer.add(dimFade, forKey: "folderDimIn")
        contentLayer.add(contentAnimation, forKey: "folderExpandIn")
        CATransaction.commit()
    }

    func animateClosing(
        contentLayer: CALayer, dimLayer: CALayer, transition: LaunchpadVisualStyle.FolderTransition,
        scale: CGFloat, completion: @escaping @MainActor () -> Void
    ) {
        let generation = folderAnimationGeneration
        // LAUNCHPANE_FOLDER_OPEN_FPS_V13
        // Re-flatten the subtree only for the short close animation.
        contentLayer.shouldRasterize = true
        contentLayer.rasterizationScale = max(1, scale)

        let dimFade = CABasicAnimation(keyPath: "opacity")
        dimFade.fromValue = dimLayer.presentation()?.opacity ?? dimLayer.opacity
        dimFade.toValue = 0
        dimFade.duration = transition.closeDuration
        dimFade.timingFunction = transition.closeTimingFunction

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = contentLayer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        scaleAnimation.toValue = transition.sourceScale
        scaleAnimation.duration = transition.closeDuration

        let contentFade = CABasicAnimation(keyPath: "opacity")
        contentFade.fromValue = contentLayer.presentation()?.opacity ?? contentLayer.opacity
        contentFade.toValue = 0
        contentFade.duration = transition.closeDuration

        let contentAnimation = CAAnimationGroup()
        contentAnimation.animations = [scaleAnimation, contentFade]
        contentAnimation.duration = transition.closeDuration
        contentAnimation.timingFunction = transition.closeTimingFunction

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.opacity = 0
        contentLayer.opacity = 0
        contentLayer.setAffineTransform(CGAffineTransform(scaleX: transition.sourceScale, y: transition.sourceScale))
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentAnimation(generation, contentLayer: contentLayer) else { return }
                completion()
            }
        }
        dimLayer.add(dimFade, forKey: "folderDimOut")
        contentLayer.add(contentAnimation, forKey: "folderCollapseOut")
        CATransaction.commit()
    }
}
