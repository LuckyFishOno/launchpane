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
                assertContained(metrics.titleFrame, in: metrics.panelFrame)
                assertContained(metrics.gridFrame, in: metrics.panelFrame)
                assertNoPositiveAreaOverlap(metrics.titleFrame, metrics.gridFrame)
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

    func testTypicalDisplayUsesFiveByThreeFolderGrid() {
        let metrics = LayoutConstraintSolver().solveFolder(
            display: makeDisplay(size: CGSize(width: 2560, height: 1440), scale: 2),
            itemCount: 100
        )

        XCTAssertEqual(metrics.columns, 5)
        XCTAssertEqual(metrics.rows, 3)
        XCTAssertEqual(metrics.itemsPerPage, 15)
        XCTAssertEqual(metrics.visibleItemCount, 15)
        XCTAssertEqual(metrics.pageCount, 7)
        XCTAssertEqual(metrics.panelFrame.midX, 1280, accuracy: 0.000_001)
        XCTAssertEqual(metrics.panelFrame.midY, 720, accuracy: 0.000_001)
    }

    func testSmallDisplayContractsGridWithoutResolutionBranching() {
        let metrics = LayoutConstraintSolver().solveFolder(
            display: makeDisplay(size: CGSize(width: 480, height: 320), scale: 1),
            itemCount: 100
        )

        XCTAssertLessThan(metrics.columns, 5)
        XCTAssertLessThan(metrics.rows, 3)
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

        for index in 0 ..< 5 {
            let mirroredIndex = 4 - index
            let ltr = try XCTUnwrap(leftToRight.cellFrame(forItemAt: index))
            let rtl = try XCTUnwrap(rightToLeft.cellFrame(forItemAt: mirroredIndex))
            XCTAssertEqual(ltr, rtl)
        }
        for index in 5 ..< 8 {
            let mirroredIndex = 12 - index
            let ltr = try XCTUnwrap(leftToRight.cellFrame(forItemAt: index))
            let rtl = try XCTUnwrap(rightToLeft.cellFrame(forItemAt: mirroredIndex))
            XCTAssertEqual(ltr, rtl)
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
        XCTAssertEqual(one.itemsPerPage, 15)
        XCTAssertEqual(one.visibleItemCount, 1)
        XCTAssertEqual(one.pageCount, 1)
        XCTAssertEqual(one.cellFrame(forItemAt: 0)?.midX, one.gridFrame.midX)
        XCTAssertNil(one.itemFrames(forItemAt: 1))

        let exactPage = solver.solveFolder(display: display, itemCount: 15)
        XCTAssertEqual(exactPage.pageCount, 1)

        let overflow = solver.solveFolder(display: display, itemCount: 16)
        XCTAssertEqual(overflow.visibleItemCount, 15)
        XCTAssertEqual(overflow.pageCount, 2)

        let negative = solver.solveFolder(display: display, itemCount: -10)
        XCTAssertEqual(negative.totalItemCount, 0)
        XCTAssertEqual(negative.pageCount, 0)
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
