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

    /// Returns a page-local cell. A partially populated final row is centered.
    public func cellFrame(forItemAt index: Int) -> CGRect? {
        guard index >= 0, index < visibleItemCount else { return nil }

        let row = index / columns
        let rowStartIndex = row * columns
        let itemsInRow = min(columns, visibleItemCount - rowStartIndex)
        let logicalColumn = index - rowStartIndex
        let column = isRightToLeft ? itemsInRow - logicalColumn - 1 : logicalColumn
        let size = cellSize
        let rowWidth = CGFloat(itemsInRow) * size.width
        let rowOriginX = gridFrame.midX - rowWidth / 2

        return CGRect(
            x: rowOriginX + CGFloat(column) * size.width,
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
