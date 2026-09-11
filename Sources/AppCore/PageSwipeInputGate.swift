/// Prevents a gesture rejected during a page animation from entering midway
/// through its event stream when that animation finishes.
public struct PageSwipeInputGate: Equatable, Sendable {
    private var ignoresCurrentGesture = false

    public init() {}

    /// Returns true when the event must not reach either paging handler.
    /// `isAnimating` includes settling and discrete page animation, but excludes
    /// a page that is currently following an accepted finger gesture.
    public mutating func consumes(
        phase: PageScrollPhase,
        momentum: PageScrollMomentum,
        isAnimating: Bool
    ) -> Bool {
        guard momentum == .none else { return true }

        switch phase {
        case .none:
            // Wheel events have no terminal phase; never latch one permanently.
            return isAnimating
        case .began:
            // A fresh gesture also recovers if a previous terminal was lost.
            ignoresCurrentGesture = isAnimating
            return ignoresCurrentGesture
        case .changed:
            ignoresCurrentGesture = ignoresCurrentGesture || isAnimating
            return ignoresCurrentGesture
        case .ended, .cancelled:
            let shouldConsume = ignoresCurrentGesture || isAnimating
            ignoresCurrentGesture = false
            return shouldConsume
        }
    }
}
