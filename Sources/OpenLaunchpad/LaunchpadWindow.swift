import AppKit
import QuartzCore

@MainActor
final class LaunchpadWindow: NSWindow {
    // OPENLAUNCHPAD_NATIVE_DOCK_TRANSITION_V2
    //
    // Timing is derived from the supplied native Launchpad recording
    // (58 fps). The reference does not visibly zoom or translate the
    // Launchpad surface: it primarily cross-fades the already-composed
    // launcher surface over the desktop.
    //
    // Open and close are intentionally asymmetric:
    //
    // - Open starts restrained and accelerates toward the resolved state.
    // - Close removes most of the launcher very early, then eases the
    //   remaining opacity away.
    //
    // This asymmetry is visible in the supplied reference and is lost when
    // both directions use ordinary symmetric cubic Bézier easing.

    private enum PresentationState {
        case hidden
        case presenting
        case visible
        case dismissing
    }

    private struct OpacityCurveSegment {
        let values: [Float]
        let keyTimes: [NSNumber]
        let remainingTimeFraction: CFTimeInterval
    }

    private enum TransitionMetrics {
        // The clean second opening in the supplied 58 fps recording reaches
        // the fully-resolved launcher in roughly 13 frames:
        //
        //     13 / 58 = 0.2241 s
        //
        // The closing transition resolves in approximately the same visual
        // interval, with a substantially more front-loaded opacity drop.
        static let openDuration: CFTimeInterval = 13.0 / 58.0
        static let closeDuration: CFTimeInterval = 13.0 / 58.0

        // For a rapid reversal we still need enough compositor time to avoid
        // creating a one-frame discontinuity.
        static let minimumReversalDuration: CFTimeInterval = 2.0 / 58.0

        static let opacityAnimationKey =
            "OpenLaunchpad.nativeWindowVisibility"

        // Measured visual progression from the supplied native reference.
        // Each value represents the launcher-visible fraction at one
        // equally-spaced point in the 13-frame transition.
        static let openOpacityCurve: [Float] = [
            0.000,
            0.064,
            0.108,
            0.161,
            0.223,
            0.293,
            0.364,
            0.447,
            0.534,
            0.621,
            0.713,
            0.818,
            0.940,
            1.000,
        ]

        static let closeOpacityCurve: [Float] = [
            1.000,
            0.702,
            0.614,
            0.525,
            0.443,
            0.364,
            0.294,
            0.232,
            0.171,
            0.117,
            0.077,
            0.039,
            0.014,
            0.000,
        ]
    }

    private var presentationState: PresentationState = .hidden
    private var transitionGeneration = 0

    // OPENLAUNCHPAD_DOCK_AGENT_ARCHITECTURE_V1
    //
    // The UI lives in an LSUIElement/accessory agent. No menu-bar
    // presentation workaround belongs in this window anymore.
    var onDidHide: (() -> Void)?
    // The menu-region background shares the main window's exact opacity curve.
    // Its unblurred desktop stays opaque underneath, so menus never shine
    // through when the frosted background fades in or out.
    weak var synchronizedBackdropLayer: CALayer?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The desktop canvas includes menu, Dock and notch regions. Those
        // reservations constrain controls in LayoutCore, not this window.
        frameRect
    }

    var isPresentedOrPresenting: Bool {
        switch presentationState {
        case .presenting, .visible:
            true
        case .hidden, .dismissing:
            false
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

        let wasVisible = isVisible
        let startOpacity: Float

        if wasVisible {
            startOpacity = freezeCurrentOpacity(of: layer)
        } else {
            startOpacity = 0
            setOpacity(0, for: layer)
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

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setOpacity(1, for: layer)
            presentationState = .visible
            return
        }

        guard startOpacity < 0.999 else {
            setOpacity(1, for: layer)
            presentationState = .visible
            return
        }

        presentationState = .presenting

        let segment = curveSegment(
            curve: TransitionMetrics.openOpacityCurve,
            startingAt: startOpacity
        )

        let duration = max(
            TransitionMetrics.minimumReversalDuration,
            TransitionMetrics.openDuration
                * segment.remainingTimeFraction
        )

        animateOpacity(
            layer: layer,
            segment: segment,
            finalOpacity: 1,
            duration: duration,
            generation: generation
        ) { [weak self] in
            guard
                let self,
                self.transitionGeneration == generation
            else {
                return
            }

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

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setOpacity(0, for: layer)
            completeDismissal()
            return
        }

        guard startOpacity > 0.001, isVisible else {
            setOpacity(0, for: layer)
            completeDismissal()
            return
        }

        presentationState = .dismissing

        let segment = curveSegment(
            curve: TransitionMetrics.closeOpacityCurve,
            startingAt: startOpacity
        )

        let duration = max(
            TransitionMetrics.minimumReversalDuration,
            TransitionMetrics.closeDuration
                * segment.remainingTimeFraction
        )

        animateOpacity(
            layer: layer,
            segment: segment,
            finalOpacity: 0,
            duration: duration,
            generation: generation
        ) { [weak self] in
            guard
                let self,
                self.transitionGeneration == generation
            else {
                return
            }

            self.completeDismissal()
        }
    }

    private func completeDismissal() {
        orderOut(nil)
        presentationState = .hidden
        onDidHide?()
    }

    private var transitionLayer: CALayer? {
        guard let contentView else {
            return nil
        }

        contentView.wantsLayer = true
        return contentView.layer
    }

    @discardableResult
    private func freezeCurrentOpacity(
        of layer: CALayer
    ) -> Float {
        let opacity =
            layer.presentation()?.opacity
                ?? layer.opacity

        layer.removeAnimation(
            forKey: TransitionMetrics.opacityAnimationKey
        )
        synchronizedBackdropLayer?.removeAnimation(forKey: TransitionMetrics.opacityAnimationKey)

        setOpacity(
            opacity,
            for: layer
        )

        return opacity
    }

    private func setOpacity(
        _ opacity: Float,
        for layer: CALayer
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        synchronizedBackdropLayer?.opacity = opacity
        CATransaction.commit()
    }

    private func curveSegment(
        curve: [Float],
        startingAt startOpacity: Float
    ) -> OpacityCurveSegment {
        guard curve.count >= 2 else {
            return OpacityCurveSegment(
                values: [
                    startOpacity,
                    curve.last ?? startOpacity,
                ],
                keyTimes: [0, 1],
                remainingTimeFraction: 1
            )
        }

        let clampedStart = min(
            1,
            max(0, startOpacity)
        )

        let step =
            1.0 / Double(curve.count - 1)

        var segmentIndex = 0
        var interpolation: Double = 0
        var found = false

        for index in 0 ..< (curve.count - 1) {
            let a = curve[index]
            let b = curve[index + 1]

            let low = min(a, b) - 0.000_001
            let high = max(a, b) + 0.000_001

            guard
                clampedStart >= low,
                clampedStart <= high
            else {
                continue
            }

            segmentIndex = index

            let delta = b - a

            if abs(delta) > 0.000_001 {
                interpolation =
                    Double((clampedStart - a) / delta)
            } else {
                interpolation = 0
            }

            interpolation = min(
                1,
                max(0, interpolation)
            )

            found = true
            break
        }

        if !found {
            let endOpacity = curve.last ?? clampedStart

            return OpacityCurveSegment(
                values: [
                    clampedStart,
                    endOpacity,
                ],
                keyTimes: [0, 1],
                remainingTimeFraction:
                    abs(endOpacity - clampedStart) < 0.001
                        ? 0
                        : 1
            )
        }

        let startTime =
            (
                Double(segmentIndex)
                    + interpolation
            )
            * step

        let remainingTime =
            max(
                0.000_001,
                1 - startTime
            )

        var values: [Float] = [
            clampedStart
        ]

        var absoluteTimes: [Double] = [
            startTime
        ]

        if segmentIndex + 1 < curve.count {
            for index in (segmentIndex + 1) ..< curve.count {
                let time =
                    Double(index)
                        * step

                if time <= startTime + 0.000_001 {
                    continue
                }

                values.append(
                    curve[index]
                )

                absoluteTimes.append(
                    time
                )
            }
        }

        let endOpacity =
            curve.last
                ?? clampedStart

        if values.count == 1 {
            values.append(
                endOpacity
            )

            absoluteTimes.append(
                1
            )
        }

        var keyTimes =
            absoluteTimes.map { absoluteTime -> NSNumber in
                let normalized =
                    (absoluteTime - startTime)
                        / remainingTime

                return NSNumber(
                    value:
                        min(
                            1,
                            max(
                                0,
                                normalized
                            )
                        )
                )
            }

        if !keyTimes.isEmpty {
            keyTimes[
                keyTimes.count - 1
            ] = 1
        }

        return OpacityCurveSegment(
            values: values,
            keyTimes: keyTimes,
            remainingTimeFraction:
                CFTimeInterval(remainingTime)
        )
    }

    private func animateOpacity(
        layer: CALayer,
        segment: OpacityCurveSegment,
        finalOpacity: Float,
        duration: CFTimeInterval,
        generation: Int,
        completion: @escaping @MainActor () -> Void
    ) {
        layer.removeAnimation(
            forKey: TransitionMetrics.opacityAnimationKey
        )
        synchronizedBackdropLayer?.removeAnimation(forKey: TransitionMetrics.opacityAnimationKey)

        setOpacity(
            finalOpacity,
            for: layer
        )

        let animation =
            CAKeyframeAnimation(
                keyPath: "opacity"
            )

        animation.values =
            segment.values

        animation.keyTimes =
            segment.keyTimes

        // The easing is encoded directly in the measured samples.
        animation.calculationMode =
            .linear

        animation.duration =
            duration

        animation.isRemovedOnCompletion =
            true

        CATransaction.begin()

        CATransaction.setCompletionBlock {
            [weak self] in

            Task {
                @MainActor [weak self] in

                guard
                    let self,
                    self.transitionGeneration
                        == generation
                else {
                    return
                }

                completion()
            }
        }

        layer.add(
            animation,
            forKey:
                TransitionMetrics
                    .opacityAnimationKey
        )
        synchronizedBackdropLayer?.add(animation, forKey: TransitionMetrics.opacityAnimationKey)

        CATransaction.commit()
    }
}
