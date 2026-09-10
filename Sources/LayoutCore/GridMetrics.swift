import CoreGraphics

public struct GridItemFrames: Equatable, Sendable {
    public let cell: CGRect
    public let icon: CGRect
    public let label: CGRect
}

public struct GridMetrics: Equatable, Sendable {
    public let rows: Int
    public let columns: Int
    public let iconSize: CGFloat
    public let labelHeight: CGFloat
    public let contentFrame: CGRect
    public let searchReservedFrame: CGRect
    public let pageIndicatorReservedFrame: CGRect
    public let isRightToLeft: Bool

    public var cellSize: CGSize {
        CGSize(
            width: contentFrame.width / CGFloat(columns),
            height: contentFrame.height / CGFloat(rows)
        )
    }

    public var itemsPerPage: Int {
        rows * columns
    }

    public func pageCount(for itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return Int(ceil(Double(itemCount) / Double(itemsPerPage)))
    }

    public func cellFrame(forItemAt index: Int) -> CGRect? {
        guard index >= 0, index < itemsPerPage else { return nil }

        let logicalColumn = index % columns
        let column = isRightToLeft ? columns - logicalColumn - 1 : logicalColumn
        let row = index / columns
        let size = cellSize

        return CGRect(
            x: contentFrame.minX + CGFloat(column) * size.width,
            y: contentFrame.maxY - CGFloat(row + 1) * size.height,
            width: size.width,
            height: size.height
        )
    }

    public func centeredCellFrame(
        forItemAt index: Int,
        visibleItemCount: Int
    ) -> CGRect? {
        let visibleItemCount = min(max(visibleItemCount, 0), itemsPerPage)
        guard index >= 0, index < visibleItemCount else { return nil }

        let row = index / columns
        let rowStartIndex = row * columns
        let itemsInRow = min(columns, visibleItemCount - rowStartIndex)
        let logicalColumn = index - rowStartIndex
        let column = isRightToLeft ? itemsInRow - logicalColumn - 1 : logicalColumn
        let size = cellSize
        let rowWidth = CGFloat(itemsInRow) * size.width
        let rowOriginX = contentFrame.midX - rowWidth / 2

        return CGRect(
            x: rowOriginX + CGFloat(column) * size.width,
            y: contentFrame.maxY - CGFloat(row + 1) * size.height,
            width: size.width,
            height: size.height
        )
    }

    public func iconFrame(forItemAt index: Int) -> CGRect? {
        guard let cell = cellFrame(forItemAt: index) else { return nil }
        return iconFrame(in: cell)
    }

    public func centeredIconFrame(
        forItemAt index: Int,
        visibleItemCount: Int
    ) -> CGRect? {
        guard let cell = centeredCellFrame(
            forItemAt: index,
            visibleItemCount: visibleItemCount
        ) else { return nil }
        return iconFrame(in: cell)
    }

    public func labelFrame(forItemAt index: Int) -> CGRect? {
        guard let cell = cellFrame(forItemAt: index) else { return nil }
        return labelFrame(in: cell)
    }

    public func centeredLabelFrame(
        forItemAt index: Int,
        visibleItemCount: Int
    ) -> CGRect? {
        guard let cell = centeredCellFrame(
            forItemAt: index,
            visibleItemCount: visibleItemCount
        ) else { return nil }
        return labelFrame(in: cell)
    }

    public func itemFrames(forItemAt index: Int) -> GridItemFrames? {
        guard let cell = cellFrame(forItemAt: index) else { return nil }
        return itemFrames(in: cell)
    }

    public func centeredItemFrames(
        forItemAt index: Int,
        visibleItemCount: Int
    ) -> GridItemFrames? {
        guard let cell = centeredCellFrame(
            forItemAt: index,
            visibleItemCount: visibleItemCount
        ) else { return nil }
        return itemFrames(in: cell)
    }
}

private extension GridMetrics {
    func itemFrames(in cell: CGRect) -> GridItemFrames {
        GridItemFrames(
            cell: cell,
            icon: iconFrame(in: cell),
            label: labelFrame(in: cell)
        )
    }

    func iconFrame(in cell: CGRect) -> CGRect {
        let combinedHeight = iconSize + labelHeight
        let bottom = cell.midY - combinedHeight / 2

        return CGRect(
            x: cell.midX - iconSize / 2,
            y: bottom + labelHeight,
            width: iconSize,
            height: iconSize
        )
    }

    func labelFrame(in cell: CGRect) -> CGRect {
        let combinedHeight = iconSize + labelHeight

        return CGRect(
            x: cell.minX,
            y: cell.midY - combinedHeight / 2,
            width: cell.width,
            height: labelHeight
        )
    }
}
