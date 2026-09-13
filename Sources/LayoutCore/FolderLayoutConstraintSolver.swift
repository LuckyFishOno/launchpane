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

        // OPENLAUNCHPAD_FOLDER_MATCH_ROOT_ICON_V1
        // Folder children must use the exact same *resolved* icon geometry as
        // the root grid. Do not hard-code 96pt here: the root solver may resolve
        // a smaller/larger value for another logical resolution, grid request,
        // or external display.
        // OPENLAUNCHPAD_FOLDER_MATCH_ROOT_VERTICAL_GEOMETRY_V1
        // A Folder child and a root-grid App must share the same resolved
        // vertical tile geometry, not only the same icon size. GridMetrics and
        // FolderGridMetrics both place the icon at cell.midY + labelHeight / 2.
        // Using the old 28pt Folder label height against the root's 34pt label
        // height made a Folder-origin proxy land 3pt too low, then jump upward
        // when the real root tile took ownership.
        let rootMetrics = solve(
            display: display,
            requested: requested,
            itemCount: itemCount
        )
        let rootIconSize = rootMetrics.iconSize
        let rootLabelHeight = rootMetrics.labelHeight

        let constraint = resolveFolderConstraint(
            in: display.safeBounds,
            tokens: folderTokens
        )
        let dimensions = resolveFolderGridDimensions(
            in: constraint.maximumGridSize,
            requested: requested,
            itemCount: itemCount,
            requiredIconSize: rootIconSize,
            requiredLabelHeight: rootLabelHeight,
            tokens: folderTokens
        )
        let frames = makeFolderFrames(
            in: display.safeBounds,
            constraint: constraint,
            dimensions: dimensions,
            requiredIconSize: rootIconSize,
            requiredLabelHeight: rootLabelHeight,
            tokens: folderTokens
        )
        let cellHeight = frames.grid.height / CGFloat(dimensions.rows)
        let labelHeight = min(max(0, rootLabelHeight), max(0, cellHeight - 1))
        let iconSize = resolveFolderIconSize(
            in: frames.grid,
            dimensions: dimensions,
            rootIconSize: rootIconSize,
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
        // Native Launchpad keeps the folder panel at roughly four-fifths of
        // the usable display width. The column lattice then contracts naturally
        // on smaller displays instead of using a resolution-specific branch.
        let nativePanelWidth = safeBounds.width * 0.80
        let maximumPanelSize = CGSize(
            width: max(
                1,
                min(tokens.maximumPanelWidth, safeBounds.width - margin * 2, nativePanelWidth)
            ),
            height: max(
                1,
                min(
                    tokens.maximumPanelHeight,
                    safeBounds.height - margin * 2 - tokens.titleHeight - tokens.titleToGridSpacing
                )
            )
        )
        let chrome = resolveFolderChrome(in: maximumPanelSize, tokens: tokens)
        let maximumGridSize = CGSize(
            width: max(1, maximumPanelSize.width - chrome.horizontalPadding * 2),
            height: max(1, maximumPanelSize.height - chrome.verticalPadding * 2)
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
        itemCount: Int,
        requiredIconSize: CGFloat,
        requiredLabelHeight: CGFloat,
        tokens: FolderLayoutTokens
    ) -> FolderGridDimensions {
        var columns = min(
            max(requested.requestedColumns ?? tokens.defaultColumns, 1),
            max(1, tokens.maximumColumns)
        )
        let requestedRows = requested.requestedRows
        var rows = min(
            max(requestedRows ?? tokens.defaultRows, 1),
            max(1, tokens.maximumRows)
        )
        // Column/row contraction is based on the root-resolved icon size, so a
        // folder never chooses a lattice that later forces its child icon smaller.
        let minimumCellWidth = max(requiredIconSize, tokens.minimumInteractionTarget)
            + max(0, tokens.minimumHorizontalGap)
        let minimumCellHeight = max(requiredIconSize, tokens.minimumInteractionTarget)
            + max(0, requiredLabelHeight)
            + max(0, tokens.minimumVerticalGap)

        while columns > 1, maximumGridSize.width / CGFloat(columns) < minimumCellWidth {
            columns -= 1
        }

        // Native Launchpad keeps the full column lattice but grows the folder
        // vertically only as many rows as the current page actually needs.
        if requestedRows == nil {
            let safeCount = max(1, itemCount)
            rows = min(rows, max(1, Int(ceil(Double(safeCount) / Double(columns)))))
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
        requiredIconSize: CGFloat,
        requiredLabelHeight: CGFloat,
        tokens: FolderLayoutTokens
    ) -> FolderFrames {
        let requiredCellWidth = requiredIconSize + max(0, tokens.minimumHorizontalGap)
        let requiredCellHeight = requiredIconSize
            + max(0, requiredLabelHeight)
            + max(0, tokens.minimumVerticalGap)
        let gridSize = CGSize(
            width: min(
                constraint.maximumGridSize.width,
                CGFloat(dimensions.columns)
                    * max(1, max(tokens.preferredCellWidth, requiredCellWidth))
            ),
            height: min(
                constraint.maximumGridSize.height,
                CGFloat(dimensions.rows)
                    * max(1, max(tokens.preferredCellHeight, requiredCellHeight))
            )
        )
        let chrome = constraint.chrome
        let panelSize = CGSize(
            width: gridSize.width + chrome.horizontalPadding * 2,
            height: gridSize.height + chrome.verticalPadding * 2
        )
        let minimumY = safeBounds.minY + max(0, tokens.displayMargin)
        let maximumY = safeBounds.maxY
            - max(0, tokens.displayMargin)
            - chrome.titleHeight
            - chrome.titleToGridSpacing
            - panelSize.height
        let centeredY = safeBounds.midY - panelSize.height / 2
        let panel = CGRect(
            x: safeBounds.midX - panelSize.width / 2,
            y: min(max(centeredY, minimumY), max(minimumY, maximumY)),
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
            x: panel.minX,
            y: panel.maxY + chrome.titleToGridSpacing,
            width: panel.width,
            height: chrome.titleHeight
        )
        return FolderFrames(panel: panel, title: title, grid: grid)
    }

    func resolveFolderIconSize(
        in gridFrame: CGRect,
        dimensions: FolderGridDimensions,
        rootIconSize: CGFloat,
        tokens: FolderLayoutTokens,
        labelHeight: CGFloat
    ) -> CGFloat {
        let cellWidth = gridFrame.width / CGFloat(dimensions.columns)
        let cellHeight = gridFrame.height / CGFloat(dimensions.rows)
        let maximumWidth = cellWidth - max(0, tokens.minimumHorizontalGap)
        let maximumHeight = cellHeight - labelHeight - max(0, tokens.minimumVerticalGap)
        let cellLimitedSize = max(1, min(maximumWidth, maximumHeight))

        // The lattice above is selected using rootIconSize, so the folder child
        // uses the exact same resolved icon size as the root grid. Keep the
        // geometry assertion explicit: if this ever fails, the folder lattice
        // must be fixed rather than silently shrinking the icon again.
        assert(cellLimitedSize + 0.5 >= rootIconSize)
        return max(1, rootIconSize)
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
