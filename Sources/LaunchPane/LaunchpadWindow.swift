import AppKit
import LayoutCore
import QuartzCore

@MainActor final class LaunchpadWindow: NSWindow {
    // LAUNCHPANE_NATIVE_DOCK_TRANSITION_V3_RADIAL
    //
    // The 58 fps native reference uses asymmetric opening and closing curves.
    // Foreground elements converge toward the display center on opening and
    // disperse on closing. The counter-transform keeps the wallpaper fixed.
    // Symmetric easing would lose the slow opening and fast initial dismissal.

    private enum PresentationState {
        case hidden
        case presenting
        case visible
        case dismissing
    }

    private struct SpatialSnapshot {
        let foreground: CATransform3D
        let background: CATransform3D?
    }

    private struct VisibilityTransition {
        let segment: OpacityCurveSegment
        let finalOpacity: Float
        let startSpatial: SpatialSnapshot
        let finalScale: CGFloat
        let isOpening: Bool
        let duration: CFTimeInterval
        let generation: Int
    }

    private enum TransitionMetrics {
        // The clean second opening in the supplied 58 fps recording reaches
        // the fully-resolved launcher in roughly 13 frames:
        //
        //     13 / 58 = 0.2241 s
        //
        // Give the closing transition a longer interval for app launches.
        static let openDuration: CFTimeInterval = 13.0 / 58.0
        static let closeDuration: CFTimeInterval = 0.27

        // For a rapid reversal we still need enough compositor time to avoid
        // creating a one-frame discontinuity.
        static let minimumReversalDuration: CFTimeInterval = 2.0 / 58.0

        static let opacityAnimationKey = "LaunchPane.nativeWindowVisibility"

        static let spatialAnimationKey = "LaunchPane.nativeRadialMotion"

        // A restrained overscan is enough to make edge items visibly travel
        // farther than center items without cropping the final resting layout.
        static let dispersedScale: CGFloat = 1.085

        // Measured visual progression from the supplied native reference.
        // Each value represents the launcher-visible fraction at one
        // equally-spaced point in the 13-frame transition.
        static let openOpacityCurve: [Float] = [
            0.000, 0.064, 0.108, 0.161, 0.223, 0.293, 0.364, 0.447, 0.534, 0.621, 0.713, 0.818, 0.940, 1.000,
        ]

        static let closeOpacityCurve: [Float] = [
            1.000, 0.702, 0.614, 0.525, 0.443, 0.364, 0.294, 0.232, 0.171, 0.117, 0.077, 0.039, 0.014, 0.000,
        ]
    }

    private var presentationState: PresentationState = .hidden
    private var transitionGeneration = 0

    // Page/folder previews can hide the transparent hit target while its drag
    // proxy remains visible. NSWindow's normal dispatch skips a hidden view,
    // even if it still owns mouseDown and remains in the hierarchy. Keep the
    // physical gesture owner independent of the presentation's visibility.
    private weak var pointerTrackingTileButton: PointerTrackingTileButton?

    func beginTilePointerTracking(_ button: PointerTrackingTileButton) {
        if let previous = pointerTrackingTileButton, previous !== button { previous.cancelPointerTracking() }
        pointerTrackingTileButton = button
    }

    func endTilePointerTracking(_ button: PointerTrackingTileButton) {
        if pointerTrackingTileButton === button { pointerTrackingTileButton = nil }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDragged || event.type == .leftMouseUp, let owner = pointerTrackingTileButton {
            if owner.window === self, owner.isTrackingPointer {
                if event.type == .leftMouseDragged {
                    owner.mouseDragged(with: event)
                } else {
                    owner.mouseUp(with: event)
                }
                // Deliver exactly once; mouseUp resets ownership before its
                // callback can commit a layout or replace the source surface.
                return
            }
            pointerTrackingTileButton = nil
        }
        super.sendEvent(event)
    }

    // LAUNCHPANE_DOCK_AGENT_ARCHITECTURE_V1
    //
    // The UI lives in an LSUIElement/accessory agent. No menu-bar
    // presentation workaround belongs in this window anymore.
    var onDidHide: (() -> Void)?
    // The entire menu-region cover shares the main window's opacity curve.
    weak var synchronizedBackdropLayer: CALayer?

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The desktop canvas includes menu, Dock and notch regions. Those
        // reservations constrain controls in LayoutCore, not this window.
        frameRect
    }

    var isPresentedOrPresenting: Bool {
        switch presentationState {
        case .presenting, .visible: true
        case .hidden, .dismissing: false
        }
    }

    func present() {
        transitionGeneration &+= 1
        let generation = transitionGeneration

        guard let layer = transitionLayer else {
            alphaValue = 1
            makeKeyAndOrderFront(nil)
            presentationState = .visible
            return
        }

        let (startOpacity, startSpatial) = prepareOpening(layer: layer)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setOpacity(1, for: layer)
            setSpatialScale(1, foregroundLayer: layer)
            presentationState = .visible
            return
        }

        guard startOpacity < 0.999 else {
            setOpacity(1, for: layer)
            setSpatialScale(1, foregroundLayer: layer)
            presentationState = .visible
            return
        }

        presentationState = .presenting

        let segment = OpacityCurveSegment.make(curve: TransitionMetrics.openOpacityCurve, startingAt: startOpacity)

        let duration = max(
            TransitionMetrics.minimumReversalDuration, TransitionMetrics.openDuration * segment.remainingTimeFraction)

        animateVisibility(
            layer: layer,
            transition: VisibilityTransition(
                segment: segment, finalOpacity: 1, startSpatial: startSpatial, finalScale: 1, isOpening: true,
                duration: duration, generation: generation)
        ) { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }

            self.presentationState = .visible
        }
    }

    func dismiss() {
        transitionGeneration &+= 1
        let generation = transitionGeneration

        guard let layer = transitionLayer else {
            completeDismissal()
            return
        }

        let startOpacity = freezeCurrentOpacity(of: layer)
        let startSpatial = freezeCurrentSpatialState(of: layer)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setOpacity(0, for: layer)
            setSpatialScale(1, foregroundLayer: layer)
            completeDismissal()
            return
        }

        guard startOpacity > 0.001, isVisible else {
            setOpacity(0, for: layer)
            setSpatialScale(1, foregroundLayer: layer)
            completeDismissal()
            return
        }

        presentationState = .dismissing

        let segment = OpacityCurveSegment.make(curve: TransitionMetrics.closeOpacityCurve, startingAt: startOpacity)

        let duration = max(
            TransitionMetrics.minimumReversalDuration, TransitionMetrics.closeDuration * segment.remainingTimeFraction)

        animateVisibility(
            layer: layer,
            transition: VisibilityTransition(
                segment: segment, finalOpacity: 0, startSpatial: startSpatial,
                finalScale: TransitionMetrics.dispersedScale, isOpening: false, duration: duration,
                generation: generation)
        ) { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }

            self.completeDismissal()
        }
    }

    private func completeDismissal() {
        if let layer = transitionLayer { setSpatialScale(1, foregroundLayer: layer) }
        orderOut(nil)
        presentationState = .hidden
        onDidHide?()
    }

}

// Layer state and animation construction stay together so opening, dismissal,
// and rapid reversals share the same compositor operations.
extension LaunchpadWindow {
    private func prepareOpening(layer: CALayer) -> (Float, SpatialSnapshot) {
        let wasVisible = isVisible
        let startOpacity: Float
        let startSpatial: SpatialSnapshot

        if wasVisible {
            startOpacity = freezeCurrentOpacity(of: layer)
            startSpatial = freezeCurrentSpatialState(of: layer)
        } else {
            startOpacity = 0
            setOpacity(0, for: layer)
            startSpatial = spatialSnapshot(scale: TransitionMetrics.dispersedScale)
            setSpatialState(startSpatial, foregroundLayer: layer)
        }

        alphaValue = 1

        // Important ordering: the content is transparent before the window is
        // ordered front, so there is no one-frame full-opacity flash.
        if !wasVisible {
            makeKeyAndOrderFront(nil)
        } else {
            makeKey()
            orderFrontRegardless()
        }

        return (startOpacity, startSpatial)
    }

    private var transitionLayer: CALayer? {
        guard let contentView else { return nil }

        contentView.wantsLayer = true
        return contentView.layer
    }

    private var counterScaledBackgroundLayer: CALayer? {
        (contentView as? LaunchpadRootView)?.presentationBackgroundLayer
    }

    @discardableResult private func freezeCurrentOpacity(of layer: CALayer) -> Float {
        let opacity = layer.presentation()?.opacity ?? layer.opacity

        layer.removeAnimation(forKey: TransitionMetrics.opacityAnimationKey)
        synchronizedBackdropLayer?.removeAnimation(forKey: TransitionMetrics.opacityAnimationKey)

        setOpacity(opacity, for: layer)

        return opacity
    }

    private func setOpacity(_ opacity: Float, for layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        synchronizedBackdropLayer?.opacity = opacity
        CATransaction.commit()
    }

    private func spatialSnapshot(scale: CGFloat) -> SpatialSnapshot {
        SpatialSnapshot(
            foreground: centeredTransform(for: transitionLayer, scale: scale),
            background: centeredTransform(for: counterScaledBackgroundLayer, scale: 1 / scale))
    }

    private func centeredTransform(for layer: CALayer?, scale: CGFloat) -> CATransform3D {
        guard let layer else { return CATransform3DIdentity }
        return CATransform3DMakeAffineTransform(
            CenteredPresentationTransform.make(bounds: layer.bounds, anchorPoint: layer.anchorPoint, scale: scale))
    }

    private func setSpatialScale(_ scale: CGFloat, foregroundLayer: CALayer) {
        setSpatialState(spatialSnapshot(scale: scale), foregroundLayer: foregroundLayer)
    }

    private func setSpatialState(_ snapshot: SpatialSnapshot, foregroundLayer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        foregroundLayer.transform = snapshot.foreground
        if let background = snapshot.background { counterScaledBackgroundLayer?.transform = background }
        CATransaction.commit()
    }

    private func freezeCurrentSpatialState(of foregroundLayer: CALayer) -> SpatialSnapshot {
        let foreground = foregroundLayer.presentation()?.transform ?? foregroundLayer.transform
        let background = counterScaledBackgroundLayer.map { $0.presentation()?.transform ?? $0.transform }

        foregroundLayer.removeAnimation(forKey: TransitionMetrics.spatialAnimationKey)
        counterScaledBackgroundLayer?.removeAnimation(forKey: TransitionMetrics.spatialAnimationKey)

        let snapshot = SpatialSnapshot(foreground: foreground, background: background)
        setSpatialState(snapshot, foregroundLayer: foregroundLayer)
        return snapshot
    }

    private func animateVisibility(
        layer: CALayer, transition: VisibilityTransition, completion: @escaping @MainActor () -> Void
    ) {
        layer.removeAnimation(forKey: TransitionMetrics.opacityAnimationKey)
        synchronizedBackdropLayer?.removeAnimation(forKey: TransitionMetrics.opacityAnimationKey)
        layer.removeAnimation(forKey: TransitionMetrics.spatialAnimationKey)
        counterScaledBackgroundLayer?.removeAnimation(forKey: TransitionMetrics.spatialAnimationKey)

        setOpacity(transition.finalOpacity, for: layer)
        let finalSpatial = spatialSnapshot(scale: transition.finalScale)
        setSpatialState(finalSpatial, foregroundLayer: layer)

        let animation = makeOpacityAnimation(transition)
        let foregroundMotion = makeSpatialAnimation(
            from: transition.startSpatial.foreground, to: finalSpatial.foreground, transition: transition)
        let backgroundMotion = makeSpatialAnimation(
            from: transition.startSpatial.background, to: finalSpatial.background, transition: transition)

        CATransaction.begin()

        CATransaction.setCompletionBlock { [weak self] in

            Task { @MainActor [weak self] in

                guard let self, self.transitionGeneration == transition.generation else { return }

                completion()
            }
        }

        layer.add(animation, forKey: TransitionMetrics.opacityAnimationKey)
        synchronizedBackdropLayer?.add(animation, forKey: TransitionMetrics.opacityAnimationKey)
        layer.add(foregroundMotion, forKey: TransitionMetrics.spatialAnimationKey)
        if transition.startSpatial.background != nil, finalSpatial.background != nil {
            counterScaledBackgroundLayer?.add(backgroundMotion, forKey: TransitionMetrics.spatialAnimationKey)
        }

        CATransaction.commit()
    }

    private func makeOpacityAnimation(_ transition: VisibilityTransition) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = transition.segment.values
        animation.keyTimes = transition.segment.keyTimes
        // The easing is encoded directly in the measured samples.
        animation.calculationMode = .linear
        animation.duration = transition.duration
        animation.isRemovedOnCompletion = true
        return animation
    }

    private func makeSpatialAnimation(
        from start: CATransform3D?, to end: CATransform3D?, transition: VisibilityTransition
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = start.map(NSValue.init(caTransform3D:))
        animation.toValue = end.map(NSValue.init(caTransform3D:))
        animation.duration = transition.duration
        animation.timingFunction = radialTimingFunction(isOpening: transition.isOpening)
        animation.isRemovedOnCompletion = true
        return animation
    }

    private func radialTimingFunction(isOpening: Bool) -> CAMediaTimingFunction {
        if isOpening { return CAMediaTimingFunction(controlPoints: 0.18, 0.72, 0.22, 1) }

        return CAMediaTimingFunction(controlPoints: 0.55, 0, 0.84, 0.30)
    }
}
