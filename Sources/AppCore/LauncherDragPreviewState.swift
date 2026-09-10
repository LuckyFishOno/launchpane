public enum LauncherDragPreviewUpdate: Equatable, Sendable {
    case none
    case materialize
    case reflow
}

/// Tracks the visual reorder preview independently from the persisted drag draft.
///
/// Keeping the initial destination virtual avoids constructing a duplicate page at
/// drag activation time. The first real move materializes the preview; subsequent
/// moves reflow that existing surface.
public struct LauncherDragPreviewState: Equatable, Sendable {
    public private(set) var destination: LauncherLayoutItemIdentifier
    public private(set) var isMaterialized = false

    public init(source: LauncherLayoutItemIdentifier) {
        destination = source
    }

    public mutating func request(
        destination nextDestination: LauncherLayoutItemIdentifier
    ) -> LauncherDragPreviewUpdate {
        guard nextDestination != destination else {
            return .none
        }

        destination = nextDestination

        if isMaterialized {
            return .reflow
        }

        isMaterialized = true
        return .materialize
    }
}
