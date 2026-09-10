import Foundation

public struct PageTransitionState: Equatable, Sendable {
    public private(set) var isAnimating = false

    private var queuedDirection = 0

    public init() {}

    public mutating func begin() {
        isAnimating = true
        queuedDirection = 0
    }

    @discardableResult
    public mutating func queueLatest(direction: Int) -> Bool {
        guard isAnimating else { return false }
        queuedDirection = direction.signum()
        return true
    }

    @discardableResult
    public mutating func finish() -> Int {
        let direction = queuedDirection
        isAnimating = false
        queuedDirection = 0
        return direction
    }

    public mutating func reset() {
        isAnimating = false
        queuedDirection = 0
    }
}

/// Platform-independent phases used by the launcher's paging gesture logic.
/// Keeping this state free of AppKit makes sensitivity and one-page-per-gesture
/// behavior deterministic in tests.
public enum PageScrollPhase: Equatable, Sendable {
    case none
    case began
    case changed
    case ended
    case cancelled
}

public enum PageScrollMomentum: Equatable, Sendable {
    case none
    case active
    case ended
}

public struct PageScrollInput: Equatable, Sendable {
    public let delta: Double
    public let hasPreciseDeltas: Bool
    public let phase: PageScrollPhase
    public let momentum: PageScrollMomentum
    public let timestamp: TimeInterval

    public init(
        delta: Double,
        hasPreciseDeltas: Bool,
        phase: PageScrollPhase,
        momentum: PageScrollMomentum,
        timestamp: TimeInterval
    ) {
        self.delta = delta
        self.hasPreciseDeltas = hasPreciseDeltas
        self.phase = phase
        self.momentum = momentum
        self.timestamp = timestamp
    }
}

public struct PageScrollGestureState: Equatable, Sendable {
    public struct Configuration: Equatable, Sendable {
        public let preciseThreshold: Double
        public let phaseLessGestureInterval: TimeInterval

        public init(
            preciseThreshold: Double = 8,
            phaseLessGestureInterval: TimeInterval = 0.24
        ) {
            self.preciseThreshold = preciseThreshold
            self.phaseLessGestureInterval = phaseLessGestureInterval
        }
    }

    private let configuration: Configuration
    private var hasPagedDuringContinuousGesture = false
    private var lastPhaseLessEventTimestamp: TimeInterval?
    private var accumulatedPreciseDelta = 0.0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func consume(_ input: PageScrollInput) -> Int? {
        if input.momentum != .none {
            if input.momentum == .ended {
                resetContinuousGesture()
            }
            return nil
        }

        if input.phase == .began {
            resetContinuousGesture()
        }

        // Terminal events only close an existing gesture. Their residual delta
        // must never create a new page turn or leave accumulated state behind.
        if input.phase == .ended || input.phase == .cancelled {
            resetContinuousGesture()
            return nil
        }

        guard input.delta != 0 else { return nil }

        if !input.hasPreciseDeltas {
            return consumeDiscrete(input)
        }

        return consumePrecise(input)
    }

    private mutating func consumePrecise(_ input: PageScrollInput) -> Int? {
        if input.phase != .none {
            guard !hasPagedDuringContinuousGesture else { return nil }
            accumulatedPreciseDelta += input.delta
            guard abs(accumulatedPreciseDelta) >= configuration.preciseThreshold else {
                return nil
            }
            hasPagedDuringContinuousGesture = true
            lastPhaseLessEventTimestamp = nil
        } else {
            let isNewPhaseLessGesture = lastPhaseLessEventTimestamp.map {
                input.timestamp - $0 > configuration.phaseLessGestureInterval
            } ?? true
            if isNewPhaseLessGesture {
                resetContinuousGesture()
            }
            lastPhaseLessEventTimestamp = input.timestamp

            guard !hasPagedDuringContinuousGesture else { return nil }
            accumulatedPreciseDelta += input.delta
            guard abs(accumulatedPreciseDelta) >= configuration.preciseThreshold else {
                return nil
            }
            hasPagedDuringContinuousGesture = true
        }

        return accumulatedPreciseDelta < 0 ? 1 : -1
    }

    private mutating func consumeDiscrete(_ input: PageScrollInput) -> Int? {
        if input.phase != .none {
            guard !hasPagedDuringContinuousGesture else { return nil }
            hasPagedDuringContinuousGesture = true
            return input.delta < 0 ? 1 : -1
        }

        // A mechanical wheel emits several phase-less notches for one flick.
        // Trigger immediately on the first notch, then hold the gesture closed
        // until the event stream has been quiet long enough to be intentional.
        let isNewGesture = lastPhaseLessEventTimestamp.map {
            input.timestamp - $0 > configuration.phaseLessGestureInterval
        } ?? true
        lastPhaseLessEventTimestamp = input.timestamp

        guard isNewGesture else { return nil }
        return input.delta < 0 ? 1 : -1
    }

    private mutating func resetContinuousGesture() {
        hasPagedDuringContinuousGesture = false
        lastPhaseLessEventTimestamp = nil
        accumulatedPreciseDelta = 0
    }
}

public enum InteractivePageSwipeDisposition: Equatable, Sendable {
    case useDiscretePaging
    case beginOrUpdate
    case finish
    case cancel
}

public enum InteractivePageSwipeDecision {
    public static func disposition(
        hasActiveSwipe: Bool,
        phase: PageScrollPhase,
        hasHorizontalMovement: Bool,
        isHorizontalDominant: Bool,
        reduceMotion: Bool
    ) -> InteractivePageSwipeDisposition {
        guard !reduceMotion else { return .useDiscretePaging }

        if hasActiveSwipe {
            if phase == .cancelled {
                return .cancel
            }
            if phase == .ended {
                return .finish
            }
            return .beginOrUpdate
        }

        // An ended/cancelled event may arrive after the view was rebuilt or a
        // boundary swipe was rejected. It can close state, but cannot open it.
        guard phase != .ended, phase != .cancelled else {
            return .useDiscretePaging
        }
        guard hasHorizontalMovement, isHorizontalDominant else {
            return .useDiscretePaging
        }
        return .beginOrUpdate
    }
}
