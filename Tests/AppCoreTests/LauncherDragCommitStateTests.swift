@testable import AppCore
import XCTest

final class LauncherDragCommitStateTests: XCTestCase {
    func testPersistenceCannotFinalizeBeforeLandingFinishes() {
        var state = LauncherDragCommitState()

        XCTAssertFalse(state.markPersistenceFinished())
        XCTAssertFalse(state.isReadyToFinalize)
        XCTAssertTrue(state.markVisualsFinished())
    }

    func testLandingCannotFinalizeBeforePersistenceFinishes() {
        var state = LauncherDragCommitState()

        XCTAssertFalse(state.markVisualsFinished())
        XCTAssertFalse(state.isReadyToFinalize)
        XCTAssertTrue(state.markPersistenceFinished())
    }

    func testFailureCanTerminateBothSidesImmediately() {
        var state = LauncherDragCommitState()

        XCTAssertTrue(state.finishImmediately())
        XCTAssertTrue(state.isReadyToFinalize)
    }
}
