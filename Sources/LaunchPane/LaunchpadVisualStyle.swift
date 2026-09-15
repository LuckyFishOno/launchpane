import AppCore
import AppKit
import QuartzCore

@MainActor
enum LaunchpadVisualStyle {
    struct PageTransition {
        let duration: CFTimeInterval
        let timingFunction: CAMediaTimingFunction
        let travelDistance: CGFloat
    }

    struct FolderTransition {
        let openDuration: CFTimeInterval
        let closeDuration: CFTimeInterval
        let sourceScale: CGFloat
        let openTimingFunction: CAMediaTimingFunction
        let closeTimingFunction: CAMediaTimingFunction
    }

    struct DragReflowTransition {
        let duration: CFTimeInterval
        let enteringItemFadeDuration: CFTimeInterval
        let enteringItemOffset: CGFloat
        let timingFunction: CAMediaTimingFunction
    }

    struct DragCompletionTransition {
        let duration: CFTimeInterval
        let timingFunction: CAMediaTimingFunction
    }

    enum DragCompletionKind {
        case insertion
        case merge
        case rollback
    }

    private enum SearchFieldMetrics {
        static let minimumWidth: CGFloat = 268
        static let maximumWidth: CGFloat = 292
        static let proportionalWidth: CGFloat = 0.19
        static let height: CGFloat = 32
    }

    private enum FolderTransitionMetrics {
        static let openDuration: CFTimeInterval = 0.21
        // LAUNCHPANE_FOLDER_CLOSE_DURATION_020_V1

        static let closeDuration: CFTimeInterval = 0.20
        static let minimumSourceScale: CGFloat = 0.08
        static let maximumSourceScale: CGFloat = 0.18
    }

    private enum DragReflowMetrics {
        // Shared positional timing for drag insertion/reflow. Keep every landing
        // path on this one duration so ownership handoffs never change speed.
        // LAUNCHPANE_REFLOW_DURATION_025_V1
        static let duration: CFTimeInterval = 0.25
        static let enteringItemFadeDuration: CFTimeInterval = 0.15
        static let enteringItemOffset: CGFloat = 34
        static let firstControlPointX: Float = 0.42
        static let firstControlPointY: Float = 0
        static let secondControlPointX: Float = 0.58
        static let secondControlPointY: Float = 1
    }

    private enum DragCompletionMetrics {
        // LAUNCHPANE_FOLDER_ABSORB_DURATION_040_V1

        // LAUNCHPANE_FOLDER_ABSORB_DURATION_044_V1


        static let mergeDuration: CFTimeInterval = 0.25
    }

    static func searchFieldSize(forDisplayWidth displayWidth: CGFloat) -> CGSize {
        CGSize(
            width: min(
                SearchFieldMetrics.maximumWidth,
                max(SearchFieldMetrics.minimumWidth, displayWidth * SearchFieldMetrics.proportionalWidth)
            ),
            height: SearchFieldMetrics.height
        )
    }

    static func dragReflowTransition(movedForward: Bool) -> DragReflowTransition {
        DragReflowTransition(
            duration: DragReflowMetrics.duration,
            enteringItemFadeDuration: DragReflowMetrics.enteringItemFadeDuration,
            enteringItemOffset: movedForward
                ? DragReflowMetrics.enteringItemOffset
                : -DragReflowMetrics.enteringItemOffset,
            timingFunction: dragReflowTimingFunction()
        )
    }

    static func dragCompletionTransition(kind: DragCompletionKind) -> DragCompletionTransition {
        if kind == .merge {
            return DragCompletionTransition(
                duration: DragCompletionMetrics.mergeDuration,
                timingFunction: CAMediaTimingFunction(
                    controlPoints: 0.20,
                    0.80,
                    0.20,
                    1
                )
            )
        }

        // A committed insertion and a rollback are both positional moves. Match
        // them to the reflow duration so the dragged tile lands at the same
        // visible speed as the surrounding tiles making room for it.
        return DragCompletionTransition(
            duration: DragReflowMetrics.duration,
            timingFunction: dragReflowTimingFunction()
        )
    }

    private static func dragReflowTimingFunction() -> CAMediaTimingFunction {
        CAMediaTimingFunction(
            controlPoints: DragReflowMetrics.firstControlPointX,
            DragReflowMetrics.firstControlPointY,
            DragReflowMetrics.secondControlPointX,
            DragReflowMetrics.secondControlPointY
        )
    }

    static func makeSelectionLayer(
        cellFrame: CGRect,
        iconFrame: CGRect,
        selected: Bool
    ) -> CALayer {
        let localIconFrame = iconFrame.offsetBy(dx: -cellFrame.minX, dy: -cellFrame.minY)
        let layer = CALayer()
        layer.frame = localIconFrame.insetBy(dx: -7, dy: -7)
        layer.cornerRadius = max(18, layer.bounds.width * 0.24)
        layer.cornerCurve = .continuous
        layer.allowsEdgeAntialiasing = true
        layer.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer.borderWidth = 0.7
        layer.opacity = selected ? 1 : 0
        return layer
    }

    static func pageTransition(direction: Int, displayWidth: CGFloat) -> PageTransition? {
        guard
            direction != 0,
            displayWidth.isFinite, displayWidth > 0,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            return nil
        }

        return pageTransition(profile: .discrete, displayWidth: displayWidth)
    }

    static func interactivePageSettleTransition(
        direction: Int,
        displayWidth: CGFloat,
        releaseVelocity: CGFloat,
        targetDelta: CGFloat
    ) -> PageTransition? {
        guard
            direction != 0,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let profile = PageMotionProfile.settle(
                displayWidth: Double(displayWidth),
                targetDelta: Double(targetDelta),
                releaseVelocity: Double(releaseVelocity)
            )
        else {
            return nil
        }

        return pageTransition(profile: profile, displayWidth: displayWidth)
    }

    private static func pageTransition(
        profile: PageMotionProfile,
        displayWidth: CGFloat
    ) -> PageTransition {
        return PageTransition(
            duration: profile.duration,
            timingFunction: CAMediaTimingFunction(
                controlPoints: Float(profile.firstControlPoint.x),
                Float(profile.firstControlPoint.y),
                Float(profile.secondControlPoint.x),
                Float(profile.secondControlPoint.y)
            ),
            travelDistance: displayWidth
        )
    }

    static func folderTransition(
        sourceFrame: CGRect?,
        panelFrame: CGRect
    ) -> FolderTransition? {
        guard
            panelFrame.width > 0,
            panelFrame.height > 0,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            return nil
        }

        let measuredSourceScale: CGFloat
        if let sourceFrame, sourceFrame.width > 0, sourceFrame.height > 0 {
            measuredSourceScale = max(
                sourceFrame.width / panelFrame.width,
                sourceFrame.height / panelFrame.height
            )
        } else {
            // Keyboard activation has no pointer source. A restrained scale keeps
            // the transition natural without pretending it came from a tile.
            measuredSourceScale = 0.14
        }

        return FolderTransition(
            openDuration: FolderTransitionMetrics.openDuration,
            closeDuration: FolderTransitionMetrics.closeDuration,
            sourceScale: min(
                FolderTransitionMetrics.maximumSourceScale,
                max(FolderTransitionMetrics.minimumSourceScale, measuredSourceScale)
            ),
            openTimingFunction: CAMediaTimingFunction(
                controlPoints: 0.16,
                0.88,
                0.20,
                1
            ),
            closeTimingFunction: CAMediaTimingFunction(
                controlPoints: 0.40,
                0,
                0.78,
                0.22
            )
        )
    }
}

@MainActor
final class PageTransitionAnimator {
    struct Request {
        let outgoingLayer: CALayer
        let incomingLayer: CALayer
        let direction: Int
        let style: LaunchpadVisualStyle.PageTransition
        let canvasBounds: CGRect
    }

    var isAnimating: Bool {
        transitionState.isAnimating
    }

    private var transitionState = PageTransitionState()
    private var generation = 0
    private weak var outgoingLayer: CALayer?
    private weak var incomingLayer: CALayer?
    private var completion: ((Int) -> Void)?

    @discardableResult
    func queueLatestIfAnimating(direction: Int) -> Bool {
        transitionState.queueLatest(direction: direction)
    }

    func start(_ request: Request, completion: @escaping (Int) -> Void) {
        let normalizedDirection: CGFloat = request.direction > 0 ? 1 : -1
        let horizontalOffset = normalizedDirection * request.style.travelDistance
        let restingPosition = CGPoint(x: request.canvasBounds.midX, y: request.canvasBounds.midY)
        let outgoingPosition = CGPoint(
            x: restingPosition.x - horizontalOffset,
            y: restingPosition.y
        )
        let incomingPosition = CGPoint(
            x: restingPosition.x + horizontalOffset,
            y: restingPosition.y
        )

        transitionState.begin()
        generation &+= 1
        let animationGeneration = generation
        outgoingLayer = request.outgoingLayer
        incomingLayer = request.incomingLayer
        self.completion = completion

        prepareLayersForAnimation(request)

        let outgoingAnimation = positionAnimation(
            from: restingPosition,
            to: outgoingPosition,
            style: request.style
        )
        let incomingAnimation = positionAnimation(
            from: incomingPosition,
            to: restingPosition,
            style: request.style
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak outgoingLayer = request.outgoingLayer] in
            Task { @MainActor [weak self, weak outgoingLayer] in
                self?.finish(
                    outgoingLayer: outgoingLayer,
                    generation: animationGeneration
                )
            }
        }
        request.outgoingLayer.position = outgoingPosition
        request.incomingLayer.position = restingPosition
        request.outgoingLayer.add(outgoingAnimation, forKey: "pageSlideOut")
        request.incomingLayer.add(incomingAnimation, forKey: "pageSlideIn")
        CATransaction.commit()
    }

    func reset(contentLayer: CALayer, canvasBounds: CGRect) {
        generation &+= 1
        transitionState.reset()
        completion = nil

        outgoingLayer?.removeAllAnimations()
        outgoingLayer?.removeFromSuperlayer()
        outgoingLayer?.shouldRasterize = false
        outgoingLayer = nil
        incomingLayer?.removeAllAnimations()
        incomingLayer?.shouldRasterize = false
        incomingLayer = nil
        contentLayer.removeAllAnimations()
        contentLayer.shouldRasterize = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = canvasBounds
        CATransaction.commit()
    }

    private func finish(outgoingLayer: CALayer?, generation: Int) {
        guard generation == self.generation else { return }

        outgoingLayer?.removeAllAnimations()
        // The controller retains adjacent pages for the next gesture. Leave the
        // outgoing tree attached until staging decides whether it is still near;
        // detaching here only to reattach it in completion churns the render tree.
        outgoingLayer?.shouldRasterize = false
        self.outgoingLayer = nil
        incomingLayer?.removeAllAnimations()
        incomingLayer?.shouldRasterize = false
        incomingLayer = nil
        let queuedDirection = transitionState.finish()
        let completion = completion
        self.completion = nil
        completion?(queuedDirection)
    }

    private func prepareLayersForAnimation(_ request: Request) {
        // The pages are already composed from Core Animation layers. Rasterizing an
        // entire Retina/5K page forces a very large offscreen texture allocation at
        // the exact moment the gesture begins, which is the main source of paging
        // hitching. Let the window server composite the existing layer tree instead.
        request.outgoingLayer.shouldRasterize = false
        request.incomingLayer.shouldRasterize = false
    }

    private func positionAnimation(
        from startPosition: CGPoint,
        to endPosition: CGPoint,
        style: LaunchpadVisualStyle.PageTransition
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: startPosition)
        animation.toValue = NSValue(point: endPosition)
        animation.duration = style.duration
        animation.timingFunction = style.timingFunction
        return animation
    }
}
