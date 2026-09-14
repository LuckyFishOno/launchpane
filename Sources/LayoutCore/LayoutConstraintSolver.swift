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
        let iconSize = resolveIconSize(
            in: frames.content,
            dimensions: dimensions,
            requested: requested,
            logicalDisplayWidth: safeBounds.width
        )

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
        let contentWidth = max(
            1,
            min(uncappedWidth, adaptiveContentWidthCap(forLogicalWidth: safeBounds.width))
        )
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
        requested: UserLayoutPreferences,
        logicalDisplayWidth: CGFloat
    ) -> CGFloat {
        let cellWidth = contentFrame.width / CGFloat(dimensions.columns)
        let cellHeight = contentFrame.height / CGFloat(dimensions.rows)
        let requestedSize = requested.requestedIconSize
            ?? adaptiveAutomaticIconSize(forLogicalWidth: logicalDisplayWidth)
        let maximumWidth = cellWidth - tokens.minimumHorizontalGap
        let maximumHeight = cellHeight - tokens.labelHeight - tokens.minimumVerticalGap
        let cellLimitedSize = max(1, min(maximumWidth, maximumHeight))

        return min(max(tokens.minimumIconSize, requestedSize), tokens.maximumIconSize, cellLimitedSize)
    }

    // OPENLAUNCHPAD_ADAPTIVE_LARGE_DISPLAY_LAYOUT_V7
    // Interpolate continuously instead of branching on a specific monitor model
    // or backing scale. A 1710pt logical canvas keeps the 108pt v6 geometry;
    // a native 3840pt logical canvas reaches 136pt. Intermediate resolutions
    // naturally land between those values. Explicit user icon-size requests are
    // intentionally handled above and bypass this automatic preference.
    private func adaptiveAutomaticIconSize(forLogicalWidth logicalWidth: CGFloat) -> CGFloat {
        let progress = largeDisplayProgress(forLogicalWidth: logicalWidth)
        let largeDisplayIconSize = min(
            tokens.maximumIconSize,
            tokens.preferredIconSize * (136.0 / 108.0)
        )
        return tokens.preferredIconSize
            + (largeDisplayIconSize - tokens.preferredIconSize) * progress
    }

    // Keep the 1710pt/MacBook composition at the familiar 1520pt content width,
    // then open the seven-column lattice gradually until it reaches 2160pt at
    // a 3840pt logical canvas. This changes horizontal spacing only; icon size,
    // rows, labels, and vertical geometry remain untouched. Custom token sets
    // with a smaller maximum remain fully respected.
    private func adaptiveContentWidthCap(forLogicalWidth logicalWidth: CGFloat) -> CGFloat {
        let baselineContentWidth = min(tokens.maximumContentWidth, 1520)
        let progress = largeDisplayProgress(forLogicalWidth: logicalWidth)
        return baselineContentWidth
            + (tokens.maximumContentWidth - baselineContentWidth) * progress
    }

    private func largeDisplayProgress(forLogicalWidth logicalWidth: CGFloat) -> CGFloat {
        let baselineLogicalWidth: CGFloat = 1710
        let largeLogicalWidth: CGFloat = 3840
        guard largeLogicalWidth > baselineLogicalWidth else { return 0 }
        return min(
            1,
            max(0, (logicalWidth - baselineLogicalWidth) / (largeLogicalWidth - baselineLogicalWidth))
        )
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
