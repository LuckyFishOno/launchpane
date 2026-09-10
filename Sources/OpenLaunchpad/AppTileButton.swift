import AppCore
import AppKit

struct TilePointerDragUpdate {
    let event: NSEvent
    let translation: CGVector
    let hasExceededActivationDistance: Bool
}

struct TilePointerRelease {
    let event: NSEvent
    let translation: CGVector
    let wasDrag: Bool
    let isClick: Bool
}

/// Shared, precise pointer handling for app and folder tiles.
///
/// Subclasses only provide identity and accessibility semantics; keeping the
/// gesture implementation here makes their click/drag thresholds identical.
@MainActor
class PointerTrackingTileButton: NSButton {
    var onHoverChanged: ((Bool) -> Void)?
    var onPointerDown: ((NSEvent) -> Void)?
    var onPointerDragged: ((TilePointerDragUpdate) -> Void)?
    var onPointerUp: ((TilePointerRelease) -> Void)?
    var onPointerCancelled: (() -> Void)?

    private enum InteractionMetrics {
        /// Logical points, intentionally independent of the display backing scale.
        static let dragActivationDistance: CGFloat = 3
        static let clickableCornerRadiusFraction: CGFloat = 0.22
    }

    private var pointerDownLocationInWindow: NSPoint?
    private(set) var hasExceededDragActivationDistance = false

    var isTrackingPointer: Bool {
        pointerDownLocationInWindow != nil
    }

    init(accessibilityLabel: String, accessibilityHelp: String) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        isTransparent = true
        focusRingType = .none
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityHelp(accessibilityHelp)
        toolTip = accessibilityLabel
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelPointerTracking()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        guard containsClickablePoint(localPoint) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if isTrackingPointer {
            cancelPointerTracking()
        }

        pointerDownLocationInWindow = event.locationInWindow
        hasExceededDragActivationDistance = false
        highlight(true)
        onPointerDown?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pointerDownLocationInWindow else { return }

        let translation = translation(
            from: pointerDownLocationInWindow,
            to: event.locationInWindow
        )
        updateDragActivation(with: translation)
        onPointerDragged?(TilePointerDragUpdate(
            event: event,
            translation: translation,
            hasExceededActivationDistance: hasExceededDragActivationDistance
        ))
    }

    override func mouseUp(with event: NSEvent) {
        guard let pointerDownLocationInWindow else { return }

        let translation = translation(
            from: pointerDownLocationInWindow,
            to: event.locationInWindow
        )
        updateDragActivation(with: translation)
        let wasDrag = hasExceededDragActivationDistance
        let localPoint = convert(event.locationInWindow, from: nil)
        let isClick = !wasDrag && containsClickablePoint(localPoint)

        resetPointerTracking()
        onPointerUp?(TilePointerRelease(
            event: event,
            translation: translation,
            wasDrag: wasDrag,
            isClick: isClick
        ))

        if isClick, let action {
            sendAction(action, to: target)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard isTrackingPointer else {
            super.cancelOperation(sender)
            return
        }
        cancelPointerTracking()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    func cancelPointerTracking() {
        guard isTrackingPointer else { return }
        resetPointerTracking()
        onPointerCancelled?()
    }

    override func mouseEntered(with _: NSEvent) {
        NSCursor.pointingHand.set()
        onHoverChanged?(true)
    }

    override func mouseExited(with _: NSEvent) {
        NSCursor.arrow.set()
        onHoverChanged?(false)
    }
}

@MainActor
final class AppTileButton: PointerTrackingTileButton {
    typealias PointerDragUpdate = TilePointerDragUpdate
    typealias PointerRelease = TilePointerRelease

    let application: ApplicationRecord

    init(application: ApplicationRecord) {
        self.application = application
        super.init(
            accessibilityLabel: application.displayName,
            accessibilityHelp: "Open \(application.displayName)"
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }
}

@MainActor
final class FolderTileButton: PointerTrackingTileButton {
    typealias PointerDragUpdate = TilePointerDragUpdate
    typealias PointerRelease = TilePointerRelease

    let folderID: UUID

    init(folderID: UUID, title: String) {
        self.folderID = folderID
        super.init(
            accessibilityLabel: title,
            accessibilityHelp: "Open folder \(title)"
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }
}

private extension PointerTrackingTileButton {
    func containsClickablePoint(_ point: NSPoint) -> Bool {
        let radius = min(bounds.width, bounds.height)
            * InteractionMetrics.clickableCornerRadiusFraction
        return NSBezierPath(
            roundedRect: bounds,
            xRadius: radius,
            yRadius: radius
        ).contains(point)
    }

    func translation(from start: NSPoint, to end: NSPoint) -> CGVector {
        CGVector(dx: end.x - start.x, dy: end.y - start.y)
    }

    func updateDragActivation(with translation: CGVector) {
        guard !hasExceededDragActivationDistance else { return }
        hasExceededDragActivationDistance = hypot(translation.dx, translation.dy)
            >= InteractionMetrics.dragActivationDistance
    }

    func resetPointerTracking() {
        pointerDownLocationInWindow = nil
        hasExceededDragActivationDistance = false
        highlight(false)
    }
}
