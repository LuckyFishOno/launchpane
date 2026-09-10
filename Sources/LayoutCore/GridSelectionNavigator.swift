public enum GridNavigationMovement: Equatable, Sendable {
    case left
    case right
    case up
    case down
}

/// Deterministic keyboard navigation for paged launcher grids.
///
/// The controller passes visual directions here. Horizontal movement is
/// mirrored for right-to-left layouts, while an empty selection begins at the
/// first item on the page that is currently visible.
public enum GridSelectionNavigator {
    public static func nextIndex(
        from currentIndex: Int?,
        movement: GridNavigationMovement,
        currentPage: Int,
        itemsPerPage: Int,
        columns: Int,
        itemCount: Int,
        isRightToLeft: Bool
    ) -> Int? {
        guard itemCount > 0, itemsPerPage > 0, columns > 0 else { return nil }

        guard let currentIndex, (0 ..< itemCount).contains(currentIndex) else {
            return min(max(0, currentPage * itemsPerPage), itemCount - 1)
        }

        let delta = switch movement {
        case .left:
            isRightToLeft ? 1 : -1
        case .right:
            isRightToLeft ? -1 : 1
        case .up:
            -columns
        case .down:
            columns
        }
        return min(max(currentIndex + delta, 0), itemCount - 1)
    }
}
