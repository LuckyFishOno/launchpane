import CoreGraphics
import DisplayCore
@testable import LayoutCore
import XCTest

final class LayoutConstraintSolverTests: XCTestCase {
    private let logicalSizes = [
        CGSize(width: 1280, height: 800),
        CGSize(width: 1366, height: 768),
        CGSize(width: 1440, height: 900),
        CGSize(width: 1470, height: 956),
        CGSize(width: 1680, height: 1050),
        CGSize(width: 1728, height: 1117),
        CGSize(width: 1920, height: 1080),
        CGSize(width: 1920, height: 1200),
        CGSize(width: 2048, height: 1152),
        CGSize(width: 2560, height: 1440),
        CGSize(width: 2560, height: 1600),
        CGSize(width: 3008, height: 1692),
        CGSize(width: 3440, height: 1440),
        CGSize(width: 3840, height: 2160),
        CGSize(width: 5120, height: 2880),
        CGSize(width: 5120, height: 1440),
    ]

    func testDisplayMatrixProducesSafeNonOverlappingGeometry() throws {
        let solver = LayoutConstraintSolver()

        for size in logicalSizes {
            for scale in [CGFloat(1), CGFloat(2)] {
                let display = makeDisplay(size: size, scale: scale)
                let metrics = solver.solve(display: display, itemCount: 250)

                XCTAssertTrue(display.safeBounds.contains(metrics.contentFrame), "Failed for \(size) @\(scale)x")
                XCTAssertFalse(metrics.contentFrame.intersects(metrics.searchReservedFrame))
                XCTAssertFalse(metrics.contentFrame.intersects(metrics.pageIndicatorReservedFrame))
                XCTAssertLessThanOrEqual(metrics.contentFrame.width, LayoutTokens.standard.maximumContentWidth)
                XCTAssertGreaterThan(metrics.iconSize, 0)

                let cells = try (0 ..< metrics.itemsPerPage).map {
                    try XCTUnwrap(metrics.cellFrame(forItemAt: $0))
                }
                for (index, cell) in cells.enumerated() {
                    assertContained(cell, in: metrics.contentFrame)
                    try assertContained(XCTUnwrap(metrics.iconFrame(forItemAt: index)), in: cell)
                    try assertContained(XCTUnwrap(metrics.labelFrame(forItemAt: index)), in: cell)

                    for otherCell in cells.dropFirst(index + 1) {
                        assertNoPositiveAreaOverlap(cell, otherCell)
                    }
                }
            }
        }
    }

    func testRequestedGridIsHonoredWhenItFits() {
        let solver = LayoutConstraintSolver()
        let preferences = UserLayoutPreferences(requestedRows: 6, requestedColumns: 9, requestedIconSize: 84)
        let metrics = solver.solve(
            display: makeDisplay(size: CGSize(width: 1920, height: 1200), scale: 2),
            requested: preferences,
            itemCount: 80
        )

        XCTAssertEqual(metrics.rows, 6)
        XCTAssertEqual(metrics.columns, 9)
        XCTAssertEqual(metrics.iconSize, 84)
        XCTAssertEqual(metrics.itemsPerPage, 54)
        XCTAssertEqual(metrics.pageCount(for: 80), 2)
    }

    func testGridContractsToProtectMinimumCellGeometry() {
        let tokens = LayoutTokens(
            minimumIconSize: 72,
            minimumHorizontalGap: 24,
            minimumVerticalGap: 24,
            minimumInteractionTarget: 72,
            maximumRows: 20,
            maximumColumns: 20
        )
        let solver = LayoutConstraintSolver(tokens: tokens)
        let metrics = solver.solve(
            display: makeDisplay(size: CGSize(width: 800, height: 600), scale: 1),
            requested: UserLayoutPreferences(requestedRows: 20, requestedColumns: 20),
            itemCount: 400
        )

        XCTAssertLessThan(metrics.rows, 20)
        XCTAssertLessThan(metrics.columns, 20)
        XCTAssertGreaterThanOrEqual(metrics.cellSize.width, 96)
        XCTAssertGreaterThanOrEqual(metrics.cellSize.height, 130)
    }

    func testRTLLayoutMirrorsCells() throws {
        let display = makeDisplay(size: CGSize(width: 1440, height: 900), scale: 2)
        let solver = LayoutConstraintSolver()
        let leftToRight = solver.solve(display: display, itemCount: 10)
        let rightToLeft = solver.solve(
            display: display,
            requested: UserLayoutPreferences(isRightToLeft: true),
            itemCount: 10
        )

        let ltrFirst = try XCTUnwrap(leftToRight.cellFrame(forItemAt: 0))
        let rtlFirst = try XCTUnwrap(rightToLeft.cellFrame(forItemAt: 0))
        XCTAssertEqual(ltrFirst.minX, rightToLeft.contentFrame.minX)
        XCTAssertEqual(rtlFirst.maxX, rightToLeft.contentFrame.maxX)
    }

    func testCenteredRowsCenterPartialSearchResults() throws {
        let metrics = LayoutConstraintSolver().solve(
            display: makeDisplay(size: CGSize(width: 1680, height: 1050), scale: 2),
            requested: UserLayoutPreferences(requestedRows: 5, requestedColumns: 7),
            itemCount: 8
        )

        let firstRowFirst = try XCTUnwrap(
            metrics.centeredCellFrame(forItemAt: 0, visibleItemCount: 8)
        )
        let firstRowLast = try XCTUnwrap(
            metrics.centeredCellFrame(forItemAt: 6, visibleItemCount: 8)
        )
        let finalRowCell = try XCTUnwrap(
            metrics.centeredCellFrame(forItemAt: 7, visibleItemCount: 8)
        )
        let finalRowIcon = try XCTUnwrap(
            metrics.centeredIconFrame(forItemAt: 7, visibleItemCount: 8)
        )
        let finalRowLabel = try XCTUnwrap(
            metrics.centeredLabelFrame(forItemAt: 7, visibleItemCount: 8)
        )

        XCTAssertEqual(firstRowFirst.minX, metrics.contentFrame.minX, accuracy: 0.000_001)
        XCTAssertEqual(firstRowLast.maxX, metrics.contentFrame.maxX, accuracy: 0.000_001)
        XCTAssertEqual(finalRowCell.midX, metrics.contentFrame.midX, accuracy: 0.000_001)
        XCTAssertEqual(finalRowIcon.midX, metrics.contentFrame.midX, accuracy: 0.000_001)
        XCTAssertEqual(finalRowLabel.midX, metrics.contentFrame.midX, accuracy: 0.000_001)
    }

    func testCenteredRowsMirrorPartialRowsForRTL() throws {
        let display = makeDisplay(size: CGSize(width: 1440, height: 900), scale: 2)
        let solver = LayoutConstraintSolver()
        let leftToRight = solver.solve(
            display: display,
            requested: UserLayoutPreferences(requestedColumns: 7),
            itemCount: 3
        )
        let rightToLeft = solver.solve(
            display: display,
            requested: UserLayoutPreferences(requestedColumns: 7, isRightToLeft: true),
            itemCount: 3
        )

        let ltrFirst = try XCTUnwrap(
            leftToRight.centeredCellFrame(forItemAt: 0, visibleItemCount: 3)
        )
        let ltrLast = try XCTUnwrap(
            leftToRight.centeredCellFrame(forItemAt: 2, visibleItemCount: 3)
        )
        let rtlFirst = try XCTUnwrap(
            rightToLeft.centeredCellFrame(forItemAt: 0, visibleItemCount: 3)
        )
        let rtlLast = try XCTUnwrap(
            rightToLeft.centeredCellFrame(forItemAt: 2, visibleItemCount: 3)
        )

        XCTAssertEqual(ltrFirst.midX, rtlLast.midX, accuracy: 0.000_001)
        XCTAssertEqual(ltrLast.midX, rtlFirst.midX, accuracy: 0.000_001)
        XCTAssertEqual(
            (ltrFirst.minX + ltrLast.maxX) / 2,
            leftToRight.contentFrame.midX,
            accuracy: 0.000_001
        )
    }

    func testNotchInsetsKeepContentInsideSafeBounds() {
        let display = DisplayContext(
            displayID: 7,
            frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            backingScaleFactor: 2,
            safeInsets: DisplayInsets(top: 38),
            hasNotch: true
        )
        let metrics = LayoutConstraintSolver().solve(display: display, itemCount: 35)

        XCTAssertTrue(display.safeBounds.contains(metrics.contentFrame))
        XCTAssertLessThanOrEqual(metrics.searchReservedFrame.maxY, display.safeBounds.maxY)
    }

    func testSolverIsDeterministic() {
        let display = makeDisplay(size: CGSize(width: 5120, height: 1440), scale: 2)
        let solver = LayoutConstraintSolver()
        let preferences = UserLayoutPreferences(requestedRows: 5, requestedColumns: 10)

        XCTAssertEqual(
            solver.solve(display: display, requested: preferences, itemCount: 91),
            solver.solve(display: display, requested: preferences, itemCount: 91)
        )
    }

    private func makeDisplay(size: CGSize, scale: CGFloat) -> DisplayContext {
        DisplayContext(
            displayID: 1,
            frame: CGRect(origin: .zero, size: size),
            visibleFrame: CGRect(origin: .zero, size: size),
            backingScaleFactor: scale
        )
    }

    private func assertContained(
        _ inner: CGRect,
        in outer: CGRect,
        accuracy: CGFloat = 0.000_001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(inner.minX, outer.minX - accuracy, file: file, line: line)
        XCTAssertGreaterThanOrEqual(inner.minY, outer.minY - accuracy, file: file, line: line)
        XCTAssertLessThanOrEqual(inner.maxX, outer.maxX + accuracy, file: file, line: line)
        XCTAssertLessThanOrEqual(inner.maxY, outer.maxY + accuracy, file: file, line: line)
    }

    private func assertNoPositiveAreaOverlap(
        _ first: CGRect,
        _ second: CGRect,
        accuracy: CGFloat = 0.000_001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let intersection = first.intersection(second)
        let hasPositiveArea = !intersection.isNull
            && intersection.width > accuracy
            && intersection.height > accuracy
        XCTAssertFalse(hasPositiveArea, file: file, line: line)
    }
}
