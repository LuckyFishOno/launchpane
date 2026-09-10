import CoreGraphics
import DisplayCore

public protocol FolderLayoutSolving: Sendable {
    func solveFolder(
        display: DisplayContext,
        requested: UserLayoutPreferences,
        itemCount: Int
    ) -> FolderGridMetrics
}

extension LayoutConstraintSolver: FolderLayoutSolving {
    public func solveFolder(
        display: DisplayContext,
        requested: UserLayoutPreferences = .automatic,
        itemCount: Int
    ) -> FolderGridMetrics {
        let folderTokens = tokens.folder
        let constraint = resolveFolderConstraint(
            in: display.safeBounds,
            tokens: folderTokens
        )
        let dimensions = resolveFolderGridDimensions(
            in: constraint.maximumGridSize,
            requested: requested,
            tokens: folderTokens
        )
        let frames = makeFolderFrames(
            in: display.safeBounds,
            constraint: constraint,
            dimensions: dimensions,
            tokens: folderTokens
        )
        let cellHeight = frames.grid.height / CGFloat(dimensions.rows)
        let labelHeight = min(max(0, folderTokens.labelHeight), max(0, cellHeight - 1))
        let iconSize = resolveFolderIconSize(
            in: frames.grid,
            dimensions: dimensions,
            requested: requested,
            tokens: folderTokens,
            labelHeight: labelHeight
        )
        let safeItemCount = max(0, itemCount)
        let itemsPerPage = dimensions.rows * dimensions.columns

        return FolderGridMetrics(
            panelFrame: frames.panel,
            titleFrame: frames.title,
            gridFrame: frames.grid,
            rows: dimensions.rows,
            columns: dimensions.columns,
            iconSize: iconSize,
            labelHeight: labelHeight,
            visibleItemCount: min(safeItemCount, itemsPerPage),
            totalItemCount: safeItemCount,
            isRightToLeft: requested.isRightToLeft
        )
    }
}

private extension LayoutConstraintSolver {
    func resolveFolderConstraint(
        in safeBounds: CGRect,
        tokens: FolderLayoutTokens
    ) -> FolderConstraint {
        let margin = min(
            max(0, tokens.displayMargin),
            max(0, min(safeBounds.width, safeBounds.height) / 4)
        )
        let maximumPanelSize = CGSize(
            width: max(1, min(tokens.maximumPanelWidth, safeBounds.width - margin * 2)),
            height: max(1, min(tokens.maximumPanelHeight, safeBounds.height - margin * 2))
        )
        let chrome = resolveFolderChrome(in: maximumPanelSize, tokens: tokens)
        let maximumGridSize = CGSize(
            width: max(1, maximumPanelSize.width - chrome.horizontalPadding * 2),
            height: max(
                1,
                maximumPanelSize.height
                    - chrome.verticalPadding * 2
                    - chrome.titleHeight
                    - chrome.titleToGridSpacing
            )
        )
        return FolderConstraint(chrome: chrome, maximumGridSize: maximumGridSize)
    }

    func resolveFolderChrome(
        in maximumPanelSize: CGSize,
        tokens: FolderLayoutTokens
    ) -> FolderChrome {
        FolderChrome(
            horizontalPadding: min(max(0, tokens.horizontalPadding), maximumPanelSize.width / 4),
            verticalPadding: min(max(0, tokens.verticalPadding), maximumPanelSize.height / 8),
            titleHeight: min(max(0, tokens.titleHeight), maximumPanelSize.height / 5),
            titleToGridSpacing: min(
                max(0, tokens.titleToGridSpacing),
                maximumPanelSize.height / 10
            )
        )
    }

    func resolveFolderGridDimensions(
        in maximumGridSize: CGSize,
        requested: UserLayoutPreferences,
        tokens: FolderLayoutTokens
    ) -> FolderGridDimensions {
        var columns = min(
            max(requested.requestedColumns ?? tokens.defaultColumns, 1),
            max(1, tokens.maximumColumns)
        )
        var rows = min(
            max(requested.requestedRows ?? tokens.defaultRows, 1),
            max(1, tokens.maximumRows)
        )
        let minimumCellWidth = max(tokens.minimumIconSize, tokens.minimumInteractionTarget)
            + max(0, tokens.minimumHorizontalGap)
        let minimumCellHeight = max(tokens.minimumIconSize, tokens.minimumInteractionTarget)
            + max(0, tokens.labelHeight)
            + max(0, tokens.minimumVerticalGap)

        while columns > 1, maximumGridSize.width / CGFloat(columns) < minimumCellWidth {
            columns -= 1
        }
        while rows > 1, maximumGridSize.height / CGFloat(rows) < minimumCellHeight {
            rows -= 1
        }
        return FolderGridDimensions(rows: rows, columns: columns)
    }

    func makeFolderFrames(
        in safeBounds: CGRect,
        constraint: FolderConstraint,
        dimensions: FolderGridDimensions,
        tokens: FolderLayoutTokens
    ) -> FolderFrames {
        let gridSize = CGSize(
            width: min(
                constraint.maximumGridSize.width,
                CGFloat(dimensions.columns) * max(1, tokens.preferredCellWidth)
            ),
            height: min(
                constraint.maximumGridSize.height,
                CGFloat(dimensions.rows) * max(1, tokens.preferredCellHeight)
            )
        )
        let chrome = constraint.chrome
        let panelSize = CGSize(
            width: gridSize.width + chrome.horizontalPadding * 2,
            height: gridSize.height
                + chrome.verticalPadding * 2
                + chrome.titleHeight
                + chrome.titleToGridSpacing
        )
        let panel = CGRect(
            x: safeBounds.midX - panelSize.width / 2,
            y: safeBounds.midY - panelSize.height / 2,
            width: panelSize.width,
            height: panelSize.height
        )
        let grid = CGRect(
            x: panel.minX + chrome.horizontalPadding,
            y: panel.minY + chrome.verticalPadding,
            width: gridSize.width,
            height: gridSize.height
        )
        let title = CGRect(
            x: grid.minX,
            y: grid.maxY + chrome.titleToGridSpacing,
            width: grid.width,
            height: chrome.titleHeight
        )
        return FolderFrames(panel: panel, title: title, grid: grid)
    }

    func resolveFolderIconSize(
        in gridFrame: CGRect,
        dimensions: FolderGridDimensions,
        requested: UserLayoutPreferences,
        tokens: FolderLayoutTokens,
        labelHeight: CGFloat
    ) -> CGFloat {
        let cellWidth = gridFrame.width / CGFloat(dimensions.columns)
        let cellHeight = gridFrame.height / CGFloat(dimensions.rows)
        let requestedSize = requested.requestedIconSize ?? tokens.preferredIconSize
        let maximumWidth = cellWidth - max(0, tokens.minimumHorizontalGap)
        let maximumHeight = cellHeight - labelHeight - max(0, tokens.minimumVerticalGap)
        let cellLimitedSize = max(1, min(maximumWidth, maximumHeight))

        return min(
            max(tokens.minimumIconSize, requestedSize),
            tokens.maximumIconSize,
            cellLimitedSize
        )
    }
}

private struct FolderGridDimensions {
    let rows: Int
    let columns: Int
}

private struct FolderChrome {
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let titleHeight: CGFloat
    let titleToGridSpacing: CGFloat
}

private struct FolderConstraint {
    let chrome: FolderChrome
    let maximumGridSize: CGSize
}

private struct FolderFrames {
    let panel: CGRect
    let title: CGRect
    let grid: CGRect
}
