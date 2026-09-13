import CoreGraphics

public struct FolderGridMetrics: Equatable, Sendable {
    public let panelFrame: CGRect
    public let titleFrame: CGRect
    public let gridFrame: CGRect
    public let rows: Int
    public let columns: Int
    public let iconSize: CGFloat
    public let labelHeight: CGFloat
    public let visibleItemCount: Int
    public let totalItemCount: Int
    public let isRightToLeft: Bool

    public var cellSize: CGSize {
        CGSize(
            width: gridFrame.width / CGFloat(columns),
            height: gridFrame.height / CGFloat(rows)
        )
    }

    public var itemsPerPage: Int {
        rows * columns
    }

    public var pageCount: Int {
        guard totalItemCount > 0 else { return 0 }
        return Int(ceil(Double(totalItemCount) / Double(itemsPerPage)))
    }

    /// Returns a page-local cell. Partial rows stay aligned to the leading edge.
    public func cellFrame(forItemAt index: Int) -> CGRect? {
        guard index >= 0, index < visibleItemCount else { return nil }

        let row = index / columns
        let logicalColumn = index % columns
        let column = isRightToLeft ? columns - logicalColumn - 1 : logicalColumn
        let size = cellSize

        // Native Launchpad keeps a stable column lattice inside a folder.
        // Partial rows start at the leading edge instead of being re-centered.
        return CGRect(
            x: gridFrame.minX + CGFloat(column) * size.width,
            y: gridFrame.maxY - CGFloat(row + 1) * size.height,
            width: size.width,
            height: size.height
        )
    }

    public func iconFrame(forItemAt index: Int) -> CGRect? {
        guard let cell = cellFrame(forItemAt: index) else { return nil }
        return itemFrames(in: cell).icon
    }

    public func labelFrame(forItemAt index: Int) -> CGRect? {
        guard let cell = cellFrame(forItemAt: index) else { return nil }
        return itemFrames(in: cell).label
    }

    public func itemFrames(forItemAt index: Int) -> GridItemFrames? {
        guard let cell = cellFrame(forItemAt: index) else { return nil }
        return itemFrames(in: cell)
    }
}

private extension FolderGridMetrics {
    func itemFrames(in cell: CGRect) -> GridItemFrames {
        let combinedHeight = iconSize + labelHeight
        let contentMinY = cell.midY - combinedHeight / 2
        let icon = CGRect(
            x: cell.midX - iconSize / 2,
            y: contentMinY + labelHeight,
            width: iconSize,
            height: iconSize
        )
        let label = CGRect(
            x: cell.minX,
            y: contentMinY,
            width: cell.width,
            height: labelHeight
        )
        return GridItemFrames(cell: cell, icon: icon, label: label)
    }
}
