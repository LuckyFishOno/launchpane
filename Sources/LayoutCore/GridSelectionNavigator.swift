public enum GridNavigationMovement: Equatable, Sendable {
    case left
    case right
    case up
    case down
}

/// Page geometry and catalog bounds used by one keyboard navigation step.
public struct GridNavigationContext: Equatable, Sendable {
    public let currentPage: Int
    public let itemsPerPage: Int
    public let columns: Int
    public let itemCount: Int
    public let isRightToLeft: Bool

    public init(currentPage: Int, itemsPerPage: Int, columns: Int, itemCount: Int, isRightToLeft: Bool) {
        self.currentPage = currentPage
        self.itemsPerPage = itemsPerPage
        self.columns = columns
        self.itemCount = itemCount
        self.isRightToLeft = isRightToLeft
    }
}

/// Deterministic keyboard navigation for paged launcher grids.
///
/// The controller passes visual directions here. Horizontal movement is
/// mirrored for right-to-left layouts, while an empty selection begins at the
/// first item on the page that is currently visible.
public enum GridSelectionNavigator {
    public static func nextIndex(
        from currentIndex: Int?, movement: GridNavigationMovement, context: GridNavigationContext
    ) -> Int? {
        guard context.itemCount > 0, context.itemsPerPage > 0, context.columns > 0 else { return nil }

        guard let currentIndex, (0..<context.itemCount).contains(currentIndex) else {
            return min(max(0, context.currentPage * context.itemsPerPage), context.itemCount - 1)
        }

        let delta =
            switch movement {
            case .left: context.isRightToLeft ? 1 : -1
            case .right: context.isRightToLeft ? -1 : 1
            case .up: -context.columns
            case .down: context.columns
            }
        return min(max(currentIndex + delta, 0), context.itemCount - 1)
    }
}
