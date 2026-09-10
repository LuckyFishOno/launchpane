import CoreGraphics
import DisplayCore

public protocol LayoutSolving: Sendable {
    func solve(
        display: DisplayContext,
        requested: UserLayoutPreferences,
        itemCount: Int
    ) -> GridMetrics
}

public struct LayoutConstraintSolver: LayoutSolving, Sendable {
    public let tokens: LayoutTokens

    public init(tokens: LayoutTokens = .standard) {
        self.tokens = tokens
    }

    public func solve(
        display: DisplayContext,
        requested: UserLayoutPreferences = .automatic,
        itemCount _: Int
    ) -> GridMetrics {
        let safeBounds = display.safeBounds
        let frames = makeFrames(in: safeBounds)
        let dimensions = resolveGridDimensions(in: frames.content, requested: requested)
        let iconSize = resolveIconSize(in: frames.content, dimensions: dimensions, requested: requested)

        return GridMetrics(
            rows: dimensions.rows,
            columns: dimensions.columns,
            iconSize: iconSize,
            labelHeight: tokens.labelHeight,
            contentFrame: frames.content,
            searchReservedFrame: frames.search,
            pageIndicatorReservedFrame: frames.pageIndicator,
            isRightToLeft: requested.isRightToLeft
        )
    }

    private func makeFrames(in safeBounds: CGRect) -> LayoutFrames {
        let horizontalMargin = min(tokens.horizontalMargin, safeBounds.width / 4)
        let verticalMargin = min(tokens.verticalMargin, safeBounds.height / 4)
        let uncappedWidth = max(1, safeBounds.width - horizontalMargin * 2)
        let contentWidth = max(1, min(uncappedWidth, tokens.maximumContentWidth))
        let contentHeight = max(
            1,
            safeBounds.height - verticalMargin * 2 - tokens.searchReservation - tokens.pageIndicatorReservation
        )
        let content = CGRect(
            x: safeBounds.midX - contentWidth / 2,
            y: safeBounds.minY + verticalMargin + tokens.pageIndicatorReservation,
            width: contentWidth,
            height: contentHeight
        )
        let search = CGRect(
            x: safeBounds.minX,
            y: content.maxY,
            width: safeBounds.width,
            height: max(0, safeBounds.maxY - verticalMargin - content.maxY)
        )
        let pageIndicator = CGRect(
            x: safeBounds.minX,
            y: safeBounds.minY + verticalMargin,
            width: safeBounds.width,
            height: max(0, content.minY - safeBounds.minY - verticalMargin)
        )
        return LayoutFrames(content: content, search: search, pageIndicator: pageIndicator)
    }

    private func resolveGridDimensions(
        in contentFrame: CGRect,
        requested: UserLayoutPreferences
    ) -> GridDimensions {
        var columns = clamped(
            requested.requestedColumns ?? tokens.defaultColumns,
            lowerBound: 1,
            upperBound: max(1, tokens.maximumColumns)
        )
        var rows = clamped(
            requested.requestedRows ?? tokens.defaultRows,
            lowerBound: 1,
            upperBound: max(1, tokens.maximumRows)
        )
        let minimumCellWidth = max(tokens.minimumIconSize, tokens.minimumInteractionTarget)
            + tokens.minimumHorizontalGap
        let minimumCellHeight = max(tokens.minimumIconSize, tokens.minimumInteractionTarget)
            + tokens.labelHeight
            + tokens.minimumVerticalGap

        while columns > 1, contentFrame.width / CGFloat(columns) < minimumCellWidth {
            columns -= 1
        }
        while rows > 1, contentFrame.height / CGFloat(rows) < minimumCellHeight {
            rows -= 1
        }
        return GridDimensions(rows: rows, columns: columns)
    }

    private func resolveIconSize(
        in contentFrame: CGRect,
        dimensions: GridDimensions,
        requested: UserLayoutPreferences
    ) -> CGFloat {
        let cellWidth = contentFrame.width / CGFloat(dimensions.columns)
        let cellHeight = contentFrame.height / CGFloat(dimensions.rows)
        let requestedSize = requested.requestedIconSize ?? tokens.preferredIconSize
        let maximumWidth = cellWidth - tokens.minimumHorizontalGap
        let maximumHeight = cellHeight - tokens.labelHeight - tokens.minimumVerticalGap
        let cellLimitedSize = max(1, min(maximumWidth, maximumHeight))

        return min(max(tokens.minimumIconSize, requestedSize), tokens.maximumIconSize, cellLimitedSize)
    }

    private func clamped(_ value: Int, lowerBound: Int, upperBound: Int) -> Int {
        min(max(value, lowerBound), upperBound)
    }
}

private struct LayoutFrames {
    let content: CGRect
    let search: CGRect
    let pageIndicator: CGRect
}

private struct GridDimensions {
    let rows: Int
    let columns: Int
}
