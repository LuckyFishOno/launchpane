import CoreGraphics
@testable import LayoutCore
import XCTest

final class GridReorderInsertionTests: XCTestCase {
    private func slot(_ raw: Int, from current: Int, fraction: CGFloat, rtl: Bool = false) -> Int {
        let cell = CGRect(x: 200, y: 100, width: 120, height: 90)
        let x = rtl ? cell.maxX - cell.width * fraction : cell.minX + cell.width * fraction
        return GridReorderInsertion.resolve(
            rawSlot: raw, currentSlot: current, draggedCenterX: x,
            targetCell: cell, isRightToLeft: rtl
        )
    }

    func testUpwardDiagonalDoesNotDisplaceAnotherAppBeforeItsMidline() {
        for rtl in [false, true] {
            XCTAssertEqual(slot(12, from: 19, fraction: 0.51, rtl: rtl), 13)
            XCTAssertEqual(slot(12, from: 19, fraction: 0.50, rtl: rtl), 13)
            XCTAssertEqual(slot(12, from: 19, fraction: 0.49, rtl: rtl), 12)
        }
    }

    func testDownwardDiagonalUsesTheSameMidlineRule() {
        for rtl in [false, true] {
            XCTAssertEqual(slot(12, from: 3, fraction: 0.49, rtl: rtl), 11)
            XCTAssertEqual(slot(12, from: 3, fraction: 0.50, rtl: rtl), 11)
            XCTAssertEqual(slot(12, from: 3, fraction: 0.51, rtl: rtl), 12)
        }
    }

    func testReflowGapDoesNotOscillateAndAllowsImmediateReversal() {
        for rtl in [false, true] {
            XCTAssertEqual(slot(12, from: 13, fraction: 0.51, rtl: rtl), 13)
            XCTAssertEqual(slot(12, from: 13, fraction: 0.49, rtl: rtl), 12)
            XCTAssertEqual(slot(12, from: 12, fraction: 0.1, rtl: rtl), 12)
            XCTAssertEqual(slot(13, from: 12, fraction: 0.49, rtl: rtl), 12)
            XCTAssertEqual(slot(13, from: 12, fraction: 0.51, rtl: rtl), 13)
        }
    }

    func testFastMotionCanCrossSeveralSlotsWithoutSteppingThroughEach() {
        XCTAssertEqual(slot(5, from: 0, fraction: 0.49), 4)
        XCTAssertEqual(slot(5, from: 0, fraction: 0.51), 5)
        XCTAssertEqual(slot(0, from: 5, fraction: 0.51), 1)
        XCTAssertEqual(slot(0, from: 5, fraction: 0.49), 0)
    }
}
