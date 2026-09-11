@testable import AppCore
import XCTest

final class PageSwipeInputGateTests: XCTestCase {
    func testAcceptedFingerGestureKeepsItsChangedAndTerminalEvents() {
        var gate = PageSwipeInputGate()

        XCTAssertFalse(gate.consumes(phase: .began, momentum: .none, isAnimating: false))
        XCTAssertFalse(gate.consumes(phase: .changed, momentum: .none, isAnimating: false))
        XCTAssertFalse(gate.consumes(phase: .ended, momentum: .none, isAnimating: false))
    }

    func testDuplicateTerminalDuringSettleCannotRestartCompletion() {
        var gate = PageSwipeInputGate()

        XCTAssertFalse(gate.consumes(phase: .ended, momentum: .none, isAnimating: false))
        XCTAssertTrue(gate.consumes(phase: .ended, momentum: .none, isAnimating: true))
        XCTAssertTrue(gate.consumes(phase: .cancelled, momentum: .none, isAnimating: true))
        XCTAssertFalse(gate.consumes(phase: .began, momentum: .none, isAnimating: false))
    }

    func testGestureBeginningDuringSettleStaysBlockedAfterAnimationFinishes() {
        var gate = PageSwipeInputGate()

        XCTAssertTrue(gate.consumes(phase: .began, momentum: .none, isAnimating: true))
        XCTAssertTrue(gate.consumes(phase: .changed, momentum: .none, isAnimating: true))
        XCTAssertTrue(gate.consumes(phase: .changed, momentum: .none, isAnimating: false))
        XCTAssertTrue(gate.consumes(phase: .ended, momentum: .none, isAnimating: false))
        XCTAssertFalse(gate.consumes(phase: .changed, momentum: .none, isAnimating: false))
    }

    func testChangedDuringDiscreteAnimationBlocksTheRemainderOfThatGesture() {
        var gate = PageSwipeInputGate()

        XCTAssertFalse(gate.consumes(phase: .began, momentum: .none, isAnimating: false))
        XCTAssertTrue(gate.consumes(phase: .changed, momentum: .none, isAnimating: true))
        XCTAssertTrue(gate.consumes(phase: .changed, momentum: .none, isAnimating: false))
        XCTAssertTrue(gate.consumes(phase: .cancelled, momentum: .none, isAnimating: false))
        XCTAssertFalse(gate.consumes(phase: .changed, momentum: .none, isAnimating: false))
    }

    func testFreshBeganAfterAnimationRecoversWhenPreviousTerminalWasLost() {
        var gate = PageSwipeInputGate()

        XCTAssertTrue(gate.consumes(phase: .began, momentum: .none, isAnimating: true))
        XCTAssertFalse(gate.consumes(phase: .began, momentum: .none, isAnimating: false))
        XCTAssertFalse(gate.consumes(phase: .changed, momentum: .none, isAnimating: false))
        XCTAssertFalse(gate.consumes(phase: .ended, momentum: .none, isAnimating: false))
    }

    func testMomentumCannotReachPagingOrReleaseABlockedFingerGesture() {
        var gate = PageSwipeInputGate()

        XCTAssertTrue(gate.consumes(phase: .none, momentum: .active, isAnimating: false))
        XCTAssertTrue(gate.consumes(phase: .none, momentum: .ended, isAnimating: false))
        XCTAssertFalse(gate.consumes(phase: .began, momentum: .none, isAnimating: false))
        XCTAssertTrue(gate.consumes(phase: .began, momentum: .none, isAnimating: true))
        XCTAssertTrue(gate.consumes(phase: .none, momentum: .active, isAnimating: true))
        XCTAssertTrue(gate.consumes(phase: .none, momentum: .ended, isAnimating: false))
        XCTAssertTrue(gate.consumes(phase: .changed, momentum: .none, isAnimating: false))
        XCTAssertTrue(gate.consumes(phase: .ended, momentum: .none, isAnimating: false))
    }

    func testPhaseLessWheelIsOnlyBlockedWhileAnimationIsBusy() {
        var gate = PageSwipeInputGate()

        XCTAssertTrue(gate.consumes(phase: .none, momentum: .none, isAnimating: true))
        XCTAssertFalse(gate.consumes(phase: .none, momentum: .none, isAnimating: false))
        XCTAssertFalse(gate.consumes(phase: .changed, momentum: .none, isAnimating: false))
        XCTAssertTrue(gate.consumes(phase: .began, momentum: .none, isAnimating: true))
        XCTAssertFalse(gate.consumes(phase: .none, momentum: .none, isAnimating: false))
        XCTAssertTrue(gate.consumes(phase: .changed, momentum: .none, isAnimating: false))
    }
}
