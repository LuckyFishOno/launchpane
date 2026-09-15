import CoreGraphics
import DisplayCore
@testable import LayoutCore
import XCTest

final class FolderLayoutConstraintSolverTests: XCTestCase {
    private let logicalSizes = [
        CGSize(width: 480, height: 320),
        CGSize(width: 640, height: 480),
        CGSize(width: 1280, height: 800),
        CGSize(width: 1366, height: 768),
        CGSize(width: 1470, height: 956),
        CGSize(width: 1920, height: 1080),
        CGSize(width: 2560, height: 1440),
        CGSize(width: 3440, height: 1440),
        CGSize(width: 5120, height: 2880),
    ]

    func testDisplayMatrixKeepsFolderGeometryInsideSafeBounds() throws {
        let solver = LayoutConstraintSolver()

        for size in logicalSizes {
            for scale in [CGFloat(1), CGFloat(2)] {
                let display = makeDisplay(size: size, scale: scale)
                let metrics = solver.solveFolder(display: display, itemCount: 100)

                assertContained(metrics.panelFrame, in: display.safeBounds)
                assertContained(metrics.titleFrame, in: display.safeBounds)
                assertContained(metrics.gridFrame, in: metrics.panelFrame)
                assertNoPositiveAreaOverlap(metrics.titleFrame, metrics.panelFrame)
                XCTAssertGreaterThan(metrics.rows, 0)
                XCTAssertGreaterThan(metrics.columns, 0)
                XCTAssertLessThanOrEqual(metrics.rows, LayoutTokens.standard.folder.maximumRows)
                XCTAssertLessThanOrEqual(metrics.columns, LayoutTokens.standard.folder.maximumColumns)

                let itemFrames = try (0 ..< metrics.visibleItemCount).map {
                    try XCTUnwrap(metrics.itemFrames(forItemAt: $0))
                }
                for (index, frames) in itemFrames.enumerated() {
                    assertContained(frames.cell, in: metrics.gridFrame)
                    assertContained(frames.icon, in: frames.cell)
                    assertContained(frames.label, in: frames.cell)

                    for otherFrames in itemFrames.dropFirst(index + 1) {
                        assertNoPositiveAreaOverlap(frames.cell, otherFrames.cell)
                    }
                }
            }
        }
    }

    func testTypicalDisplayUsesSevenByFiveFolderGrid() {
        let metrics = LayoutConstraintSolver().solveFolder(
            display: makeDisplay(size: CGSize(width: 2560, height: 1440), scale: 2),
            itemCount: 100
        )

        XCTAssertEqual(metrics.columns, 7)
        XCTAssertEqual(metrics.rows, 5)
        XCTAssertEqual(metrics.itemsPerPage, 35)
        XCTAssertEqual(metrics.visibleItemCount, 35)
        XCTAssertEqual(metrics.pageCount, 3)
        XCTAssertEqual(metrics.panelFrame.midX, 1280, accuracy: 0.000_001)
        XCTAssertEqual(metrics.panelFrame.midY, 720, accuracy: 0.000_001)
    }

    func testNative4KFolderChildrenMatchAdaptiveRootIconSize() {
        let display = makeDisplay(size: CGSize(width: 3840, height: 2160), scale: 1)
        let solver = LayoutConstraintSolver()
        let root = solver.solve(display: display, itemCount: 35)
        let folder = solver.solveFolder(display: display, itemCount: 35)

        XCTAssertEqual(root.iconSize, 136, accuracy: 0.001)
        XCTAssertEqual(folder.iconSize, root.iconSize, accuracy: 0.001)

        // LAUNCHPANE_ADAPTIVE_FOLDER_PANEL_SCALE_V12
        // A native 4K folder should grow with the same 136/108 visual ratio
        // instead of staying near the baseline ~1404pt panel width.
        XCTAssertGreaterThan(folder.panelFrame.width, 1700)
        XCTAssertGreaterThan(folder.panelFrame.height, 1100)
    }

    func testSmallDisplayContractsGridWithoutResolutionBranching() {
        let metrics = LayoutConstraintSolver().solveFolder(
            display: makeDisplay(size: CGSize(width: 480, height: 320), scale: 1),
            itemCount: 100
        )

        XCTAssertLessThan(metrics.columns, 7)
        XCTAssertLessThan(metrics.rows, 5)
        XCTAssertGreaterThan(metrics.itemsPerPage, 0)
    }

    func testRTLLayoutMirrorsFullAndPartialRows() throws {
        let display = makeDisplay(size: CGSize(width: 2560, height: 1440), scale: 2)
        let solver = LayoutConstraintSolver()
        let leftToRight = solver.solveFolder(display: display, itemCount: 8)
        let rightToLeft = solver.solveFolder(
            display: display,
            requested: UserLayoutPreferences(isRightToLeft: true),
            itemCount: 8
        )

        for index in 0 ..< 8 {
            let ltr = try XCTUnwrap(leftToRight.cellFrame(forItemAt: index))
            let rtl = try XCTUnwrap(rightToLeft.cellFrame(forItemAt: index))
            XCTAssertEqual(
                ltr.midX + rtl.midX,
                leftToRight.gridFrame.minX + leftToRight.gridFrame.maxX,
                accuracy: 0.000_001
            )
            XCTAssertEqual(ltr.midY, rtl.midY, accuracy: 0.000_001)
        }
    }

    func testItemCountsHaveStableCapacityAndPageCounts() {
        let display = makeDisplay(size: CGSize(width: 2560, height: 1440), scale: 2)
        let solver = LayoutConstraintSolver()

        let empty = solver.solveFolder(display: display, itemCount: 0)
        XCTAssertEqual(empty.visibleItemCount, 0)
        XCTAssertEqual(empty.pageCount, 0)
        XCTAssertNil(empty.itemFrames(forItemAt: 0))

        let one = solver.solveFolder(display: display, itemCount: 1)
        XCTAssertEqual(one.itemsPerPage, 7)
        XCTAssertEqual(one.visibleItemCount, 1)
        XCTAssertEqual(one.pageCount, 1)
        XCTAssertEqual(one.cellFrame(forItemAt: 0)?.minX, one.gridFrame.minX)
        XCTAssertNil(one.itemFrames(forItemAt: 1))

        let exactPage = solver.solveFolder(display: display, itemCount: 35)
        XCTAssertEqual(exactPage.pageCount, 1)

        let overflow = solver.solveFolder(display: display, itemCount: 36)
        XCTAssertEqual(overflow.visibleItemCount, 35)
        XCTAssertEqual(overflow.pageCount, 2)

        let negative = solver.solveFolder(display: display, itemCount: -10)
        XCTAssertEqual(negative.totalItemCount, 0)
        XCTAssertEqual(negative.pageCount, 0)
    }

    func testNativeSizedDisplayUsesWideDynamicPanelAndLeadingRows() throws {
        let display = makeDisplay(size: CGSize(width: 1524, height: 1024), scale: 2)
        let solver = LayoutConstraintSolver()

        let tools = solver.solveFolder(display: display, itemCount: 5)
        let other = solver.solveFolder(display: display, itemCount: 33)

        XCTAssertEqual(tools.columns, 7)
        XCTAssertEqual(tools.rows, 1)
        XCTAssertEqual(other.columns, 7)
        XCTAssertEqual(other.rows, 5)
        XCTAssertEqual(tools.panelFrame.width, display.safeBounds.width * 0.80, accuracy: 0.001)
        XCTAssertEqual(other.panelFrame.width, display.safeBounds.width * 0.80, accuracy: 0.001)
        XCTAssertLessThan(tools.panelFrame.height, other.panelFrame.height)

        let finalRowFirst = try XCTUnwrap(other.cellFrame(forItemAt: 28))
        XCTAssertEqual(finalRowFirst.minX, other.gridFrame.minX, accuracy: 0.001)
    }

    func testFolderSolverHonorsPreferencesWithinFolderLimits() {
        let metrics = LayoutConstraintSolver().solveFolder(
            display: makeDisplay(size: CGSize(width: 1920, height: 1200), scale: 2),
            requested: UserLayoutPreferences(
                requestedRows: 2,
                requestedColumns: 4,
                requestedIconSize: 72
            ),
            itemCount: 24
        )

        XCTAssertEqual(metrics.rows, 2)
        XCTAssertEqual(metrics.columns, 4)
        XCTAssertEqual(metrics.iconSize, 72)
        XCTAssertEqual(metrics.itemsPerPage, 8)
        XCTAssertEqual(metrics.pageCount, 3)
    }

    func testFolderSolverIsDeterministic() {
        let display = DisplayContext(
            displayID: 9,
            frame: CGRect(x: 100, y: 50, width: 1470, height: 956),
            visibleFrame: CGRect(x: 100, y: 50, width: 1470, height: 930),
            backingScaleFactor: 2,
            safeInsets: DisplayInsets(top: 38),
            hasNotch: true
        )
        let preferences = UserLayoutPreferences(requestedIconSize: 80, isRightToLeft: true)
        let solver = LayoutConstraintSolver()

        XCTAssertEqual(
            solver.solveFolder(display: display, requested: preferences, itemCount: 31),
            solver.solveFolder(display: display, requested: preferences, itemCount: 31)
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
