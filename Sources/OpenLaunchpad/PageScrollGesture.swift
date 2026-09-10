import AppCore
import AppKit

struct PageScrollGesture {
    private var state = PageScrollGestureState()

    mutating func consume(_ event: NSEvent) -> Int? {
        let primaryDelta = dominantDelta(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY
        )
        return state.consume(PageScrollInput(
            delta: Double(primaryDelta),
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            phase: PageScrollPhase(event.phase),
            momentum: PageScrollMomentum(event.momentumPhase),
            timestamp: event.timestamp
        ))
    }

    private func dominantDelta(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat {
        abs(deltaX) > abs(deltaY) ? deltaX : deltaY
    }
}

extension PageScrollPhase {
    init(_ phase: NSEvent.Phase) {
        if phase.contains(.cancelled) {
            self = .cancelled
        } else if phase.contains(.ended) {
            self = .ended
        } else if phase.contains(.began) {
            self = .began
        } else if phase.isEmpty {
            self = .none
        } else {
            self = .changed
        }
    }
}

private extension PageScrollMomentum {
    init(_ phase: NSEvent.Phase) {
        if phase.contains(.ended) || phase.contains(.cancelled) {
            self = .ended
        } else if phase.isEmpty {
            self = .none
        } else {
            self = .active
        }
    }
}
