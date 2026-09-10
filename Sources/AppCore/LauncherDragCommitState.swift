/// Coordinates the visual landing and the persisted layout transaction.
///
/// A committed drag is complete only after both sides finish. Keeping this
/// policy outside AppKit makes the ordering deterministic and testable.
public struct LauncherDragCommitState: Equatable, Sendable {
    public private(set) var didFinishVisuals = false
    public private(set) var didFinishPersistence = false

    public init() {}

    public var isReadyToFinalize: Bool {
        didFinishVisuals && didFinishPersistence
    }

    @discardableResult
    public mutating func markVisualsFinished() -> Bool {
        didFinishVisuals = true
        return isReadyToFinalize
    }

    @discardableResult
    public mutating func markPersistenceFinished() -> Bool {
        didFinishPersistence = true
        return isReadyToFinalize
    }

    @discardableResult
    public mutating func finishImmediately() -> Bool {
        didFinishVisuals = true
        didFinishPersistence = true
        return true
    }
}
