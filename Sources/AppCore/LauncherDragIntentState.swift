import Foundation

public enum LauncherDragIntentDecision: Equatable, Sendable {
    case hold
    case ready(LauncherDropTarget)
}

/// Arbitrates the dwell before previewing a reorder or accepting a folder merge.
///
/// The caller supplies a monotonic time and a geometrically validated candidate.
/// Rendering, hit testing, and timer scheduling remain outside this state. A timer
/// must retain `generation` and verify it before submitting another update, so a
/// cancelled dwell cannot become valid again when the same target is revisited.
public struct LauncherDragIntentState: Equatable, Sendable {
    public let mergeDwell: TimeInterval
    public let reorderDwell: TimeInterval

    public private(set) var candidate: LauncherDropTarget?
    public private(set) var beganAt: TimeInterval?
    public private(set) var isReady = false
    public private(set) var generation: UInt64 = 0

    // LAUNCHPANE_MERGE_DWELL_015_V1


    public init(mergeDwell: TimeInterval = 0.15, reorderDwell: TimeInterval = 0.18) {
        precondition(mergeDwell.isFinite && mergeDwell >= 0)
        precondition(reorderDwell.isFinite && reorderDwell >= 0)
        self.mergeDwell = mergeDwell
        self.reorderDwell = reorderDwell
    }

    /// The monotonic time at which the current candidate becomes ready.
    /// Remains available after readiness until the candidate changes or resets.
    public var deadline: TimeInterval? {
        guard let candidate, let beganAt else { return nil }
        return beganAt + (candidate.isInsertion ? reorderDwell : mergeDwell)
    }

    @discardableResult
    public mutating func update(
        candidate nextCandidate: LauncherDropTarget?,
        at time: TimeInterval,
        restartDwell: Bool = false
    ) -> LauncherDragIntentDecision {
        guard let nextCandidate, nextCandidate != .outside else {
            reset()
            return .hold
        }

        if candidate != nextCandidate || restartDwell {
            generation &+= 1
            candidate = nextCandidate
            beganAt = time
            isReady = false
        }

        if let deadline, time >= deadline {
            isReady = true
        }

        return isReady ? .ready(nextCandidate) : .hold
    }

    public mutating func reset() {
        generation &+= 1
        candidate = nil
        beganAt = nil
        isReady = false
    }
}
