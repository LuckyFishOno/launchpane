@testable import LayoutCore
import XCTest

final class GridSelectionNavigatorTests: XCTestCase {
    func testEmptySelectionBeginsOnCurrentPage() {
        let index = GridSelectionNavigator.nextIndex(
            from: nil,
            movement: .left,
            currentPage: 2,
            itemsPerPage: 12,
            columns: 4,
            itemCount: 30,
            isRightToLeft: false
        )

        XCTAssertEqual(index, 24)
    }

    func testHorizontalMovementUsesVisualDirectionInLeftToRightLayout() {
        XCTAssertEqual(next(from: 5, movement: .left, isRightToLeft: false), 4)
        XCTAssertEqual(next(from: 5, movement: .right, isRightToLeft: false), 6)
    }

    func testHorizontalMovementMirrorsVisualDirectionInRightToLeftLayout() {
        XCTAssertEqual(next(from: 5, movement: .left, isRightToLeft: true), 6)
        XCTAssertEqual(next(from: 5, movement: .right, isRightToLeft: true), 4)
    }

    func testVerticalMovementUsesColumnCountAndClampsAtEdges() {
        XCTAssertEqual(next(from: 5, movement: .up), 1)
        XCTAssertEqual(next(from: 5, movement: .down), 9)
        XCTAssertEqual(next(from: 1, movement: .up), 0)
        XCTAssertEqual(next(from: 18, movement: .down), 19)
    }

    func testInvalidGeometryHasNoSelection() {
        XCTAssertNil(GridSelectionNavigator.nextIndex(
            from: nil,
            movement: .right,
            currentPage: 0,
            itemsPerPage: 0,
            columns: 0,
            itemCount: 10,
            isRightToLeft: false
        ))
    }

    private func next(
        from index: Int,
        movement: GridNavigationMovement,
        isRightToLeft: Bool = false
    ) -> Int? {
        GridSelectionNavigator.nextIndex(
            from: index,
            movement: movement,
            currentPage: 0,
            itemsPerPage: 20,
            columns: 4,
            itemCount: 20,
            isRightToLeft: isRightToLeft
        )
    }
}
