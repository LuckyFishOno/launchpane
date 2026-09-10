@testable import AppCore
import XCTest

final class PageTransitionStateTests: XCTestCase {
    func testQueueRejectsDirectionWhileIdle() {
        var state = PageTransitionState()

        XCTAssertFalse(state.queueLatest(direction: 1))
        XCTAssertFalse(state.isAnimating)
        XCTAssertEqual(state.finish(), 0)
    }

    func testFinishReturnsOnlyLatestQueuedDirection() {
        var state = PageTransitionState()
        state.begin()

        XCTAssertTrue(state.queueLatest(direction: 2))
        XCTAssertTrue(state.queueLatest(direction: -4))
        XCTAssertEqual(state.finish(), -1)
        XCTAssertFalse(state.isAnimating)
    }

    func testBeginAndResetDiscardStaleQueue() {
        var state = PageTransitionState()
        state.begin()
        state.queueLatest(direction: 1)
        state.reset()
        state.begin()

        XCTAssertTrue(state.isAnimating)
        XCTAssertEqual(state.finish(), 0)
    }

    func testLightPreciseScrollPagesOncePerContinuousGesture() {
        var state = PageScrollGestureState()

        XCTAssertNil(state.consume(input(delta: -3, phase: .began, timestamp: 1)))
        XCTAssertNil(state.consume(input(delta: -3, phase: .changed, timestamp: 1.01)))
        XCTAssertEqual(state.consume(input(delta: -2, phase: .changed, timestamp: 1.02)), 1)
        XCTAssertNil(state.consume(input(delta: -40, phase: .changed, timestamp: 1.03)))
    }

    func testTerminalEventCannotStartAContinuousGesture() {
        var state = PageScrollGestureState()

        XCTAssertNil(state.consume(input(delta: -30, phase: .ended, timestamp: 2)))
        XCTAssertNil(state.consume(input(delta: -4, phase: .changed, timestamp: 2.01)))
    }

    func testMomentumNeverRepeatsPaging() {
        var state = PageScrollGestureState()

        XCTAssertEqual(state.consume(input(delta: -8, phase: .changed, timestamp: 3)), 1)
        XCTAssertNil(state.consume(input(
            delta: -80,
            phase: .none,
            momentum: .active,
            timestamp: 3.01
        )))
        XCTAssertNil(state.consume(input(
            delta: -20,
            phase: .none,
            momentum: .ended,
            timestamp: 3.2
        )))
    }

    func testMouseWheelNotchPagesImmediately() {
        var state = PageScrollGestureState()

        XCTAssertEqual(state.consume(input(
            delta: -1,
            hasPreciseDeltas: false,
            phase: .none,
            timestamp: 4
        )), 1)
    }

    func testMouseWheelBurstOnlyPagesOnceUntilItBecomesIdle() {
        var state = PageScrollGestureState()

        XCTAssertEqual(state.consume(input(
            delta: -1,
            hasPreciseDeltas: false,
            phase: .none,
            timestamp: 5
        )), 1)
        XCTAssertNil(state.consume(input(
            delta: -12,
            hasPreciseDeltas: false,
            phase: .none,
            timestamp: 5.04
        )))
        XCTAssertNil(state.consume(input(
            delta: -30,
            hasPreciseDeltas: false,
            phase: .none,
            timestamp: 5.20
        )))
        XCTAssertEqual(state.consume(input(
            delta: -1,
            hasPreciseDeltas: false,
            phase: .none,
            timestamp: 5.50
        )), 1)
    }

    func testLargePreciseDeltaStillMovesOnlyOnePagePerGesture() {
        var state = PageScrollGestureState()

        XCTAssertEqual(state.consume(input(delta: -200, phase: .began, timestamp: 6)), 1)
        XCTAssertNil(state.consume(input(delta: -200, phase: .changed, timestamp: 6.01)))
        XCTAssertNil(state.consume(input(delta: -200, phase: .changed, timestamp: 6.02)))
    }

    func testInactiveInteractiveSwipeCannotBeginFromTerminalEvent() {
        XCTAssertEqual(
            InteractivePageSwipeDecision.disposition(
                hasActiveSwipe: false,
                phase: .ended,
                hasHorizontalMovement: true,
                isHorizontalDominant: true,
                reduceMotion: false
            ),
            .useDiscretePaging
        )
        XCTAssertEqual(
            InteractivePageSwipeDecision.disposition(
                hasActiveSwipe: false,
                phase: .cancelled,
                hasHorizontalMovement: true,
                isHorizontalDominant: true,
                reduceMotion: false
            ),
            .useDiscretePaging
        )
    }

    func testReduceMotionAlwaysUsesDiscretePaging() {
        XCTAssertEqual(
            InteractivePageSwipeDecision.disposition(
                hasActiveSwipe: true,
                phase: .changed,
                hasHorizontalMovement: true,
                isHorizontalDominant: true,
                reduceMotion: true
            ),
            .useDiscretePaging
        )
    }

    private func input(
        delta: Double,
        hasPreciseDeltas: Bool = true,
        phase: PageScrollPhase,
        momentum: PageScrollMomentum = .none,
        timestamp: TimeInterval
    ) -> PageScrollInput {
        PageScrollInput(
            delta: delta,
            hasPreciseDeltas: hasPreciseDeltas,
            phase: phase,
            momentum: momentum,
            timestamp: timestamp
        )
    }
}
