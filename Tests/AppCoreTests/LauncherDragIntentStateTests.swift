@testable import AppCore
import Foundation
import XCTest

final class LauncherDragIntentStateTests: XCTestCase {
    func testInitialStateHasNoPendingIntent() {
        let state = LauncherDragIntentState()

        XCTAssertNil(state.candidate)
        XCTAssertNil(state.beganAt)
        XCTAssertNil(state.deadline)
        XCTAssertFalse(state.isReady)
        XCTAssertEqual(state.generation, 0)
    }

    func testApplicationAndFolderMergeRequireTheirFullDwell() throws {
        let folderID = try XCTUnwrap(UUID(uuidString: "73000000-0000-0000-0000-000000000001"))
        let targets: [LauncherDropTarget] = [
            .application(applicationIdentity("alpha")),
            .folder(folderID),
        ]

        for target in targets {
            var state = LauncherDragIntentState()
            XCTAssertEqual(state.update(candidate: target, at: 10), .hold)
            let deadline = try XCTUnwrap(state.deadline)
            XCTAssertEqual(deadline, 10.15, accuracy: 0.000_001)
            XCTAssertEqual(state.update(candidate: target, at: deadline.nextDown), .hold)
            XCTAssertFalse(state.isReady)
            XCTAssertEqual(state.update(candidate: target, at: deadline), .ready(target))
            XCTAssertTrue(state.isReady)
        }
    }

    func testBothInsertionTypesUseShorterReorderDwell() throws {
        let targets: [LauncherDropTarget] = [
            .insertion(destination: .application(applicationIdentity("alpha"))),
            .pageInsertion(page: 2, index: 4),
        ]

        for target in targets {
            var state = LauncherDragIntentState()
            XCTAssertEqual(state.update(candidate: target, at: 20), .hold)
            let deadline = try XCTUnwrap(state.deadline)
            XCTAssertEqual(deadline, 20.18, accuracy: 0.000_001)
            XCTAssertEqual(state.update(candidate: target, at: deadline.nextDown), .hold)
            XCTAssertEqual(state.update(candidate: target, at: deadline), .ready(target))
        }
    }

    func testRepeatedMovementWithinSameCandidatePreservesOriginalDeadline() throws {
        let target = LauncherDropTarget.application(applicationIdentity("alpha"))
        var state = LauncherDragIntentState()
        state.update(candidate: target, at: 0)
        let generation = state.generation

        for time in [0.03, 0.08, 0.14] {
            XCTAssertEqual(state.update(candidate: target, at: time), .hold)
            XCTAssertEqual(state.beganAt, 0)
            XCTAssertEqual(state.generation, generation)
        }

        let deadline = try XCTUnwrap(state.deadline)
        XCTAssertEqual(state.update(candidate: target, at: deadline), .ready(target))
        XCTAssertEqual(state.update(candidate: target, at: 1), .ready(target))
        XCTAssertEqual(state.generation, generation)
    }

    func testStationaryCandidateBecomesReadyOnDeadlineWithoutMovementUpdates() throws {
        let target = LauncherDropTarget.application(applicationIdentity("alpha"))
        var state = LauncherDragIntentState()
        XCTAssertEqual(state.update(candidate: target, at: 0), .hold)
        let deadline = try XCTUnwrap(state.deadline)

        // Represents one validated timer callback with no intervening mouse event.
        XCTAssertEqual(state.update(candidate: target, at: deadline), .ready(target))
    }

    func testEnteringMergeRegionReplacesPendingReorderDeadline() throws {
        let insertion = LauncherDropTarget.pageInsertion(page: 0, index: 1)
        let merge = LauncherDropTarget.application(applicationIdentity("alpha"))
        var state = LauncherDragIntentState()
        state.update(candidate: insertion, at: 0)
        let insertionGeneration = state.generation

        XCTAssertEqual(state.update(candidate: merge, at: 0.12), .hold)
        XCTAssertNotEqual(state.generation, insertionGeneration)
        XCTAssertEqual(state.update(candidate: merge, at: 0.18), .hold)
        XCTAssertEqual(state.update(candidate: merge, at: 0.14), .hold)
        let deadline = try XCTUnwrap(state.deadline)
        XCTAssertEqual(deadline, 0.27, accuracy: 0.000_001)
        XCTAssertEqual(state.update(candidate: merge, at: deadline), .ready(merge))
    }

    func testLeavingArmedMergeStartsFreshInsertionDwell() throws {
        let merge = LauncherDropTarget.application(applicationIdentity("alpha"))
        let insertion = LauncherDropTarget.pageInsertion(page: 0, index: 1)
        var state = LauncherDragIntentState()
        state.update(candidate: merge, at: 0)
        XCTAssertEqual(state.update(candidate: merge, at: 0.15), .ready(merge))

        XCTAssertEqual(state.update(candidate: insertion, at: 0.5), .hold)
        XCTAssertFalse(state.isReady)
        let deadline = try XCTUnwrap(state.deadline)
        XCTAssertEqual(deadline, 0.68, accuracy: 0.000_001)
        XCTAssertEqual(state.update(candidate: insertion, at: deadline), .ready(insertion))
    }

    func testNilAndOutsideCancelPendingOrArmedCandidate() {
        let target = LauncherDropTarget.application(applicationIdentity("alpha"))
        for cancelledTarget: LauncherDropTarget? in [nil, .outside] {
            for cancelAfterReady in [false, true] {
                var state = LauncherDragIntentState()
                state.update(candidate: target, at: 0)
                if cancelAfterReady {
                    state.update(candidate: target, at: 0.15)
                }
                let previousGeneration = state.generation

                XCTAssertEqual(state.update(candidate: cancelledTarget, at: 0.5), .hold)
                XCTAssertNil(state.candidate)
                XCTAssertNil(state.beganAt)
                XCTAssertNil(state.deadline)
                XCTAssertFalse(state.isReady)
                XCTAssertNotEqual(state.generation, previousGeneration)
                XCTAssertEqual(state.update(candidate: target, at: 0.6), .hold)
                XCTAssertEqual(state.beganAt, 0.6)
            }
        }
    }

    func testMeaningfulMovementExplicitlyRestartsSameInsertionCandidate() throws {
        let target = LauncherDropTarget.pageInsertion(page: 0, index: 1)
        var state = LauncherDragIntentState()
        state.update(candidate: target, at: 0)
        let previousGeneration = state.generation

        XCTAssertEqual(state.update(candidate: target, at: 0.1, restartDwell: true), .hold)
        XCTAssertNotEqual(state.generation, previousGeneration)
        XCTAssertEqual(state.beganAt, 0.1)
        XCTAssertEqual(state.update(candidate: target, at: 0.18), .hold)
        let deadline = try XCTUnwrap(state.deadline)
        XCTAssertEqual(deadline, 0.28, accuracy: 0.000_001)
        XCTAssertEqual(state.update(candidate: target, at: deadline), .ready(target))

        XCTAssertEqual(state.update(candidate: target, at: 0.3, restartDwell: true), .hold)
        XCTAssertFalse(state.isReady)
    }

    func testRevisitingSameAppCannotReuseEarlierTimerGeneration() throws {
        let first = LauncherDropTarget.application(applicationIdentity("alpha"))
        let second = LauncherDropTarget.application(applicationIdentity("beta"))
        var state = LauncherDragIntentState()
        state.update(candidate: first, at: 0)
        let firstTimerGeneration = state.generation
        let firstTimerDeadline = try XCTUnwrap(state.deadline)
        state.update(candidate: second, at: 0.1)
        state.update(candidate: first, at: 0.2)

        XCTAssertEqual(state.candidate, first)
        XCTAssertNotEqual(state.generation, firstTimerGeneration,
                          "Identity alone cannot distinguish the cancelled dwell from the new dwell.")
        XCTAssertEqual(state.update(candidate: first, at: firstTimerDeadline), .hold)
        let validDeadline = try XCTUnwrap(state.deadline)
        XCTAssertEqual(validDeadline, 0.35, accuracy: 0.000_001)
        XCTAssertEqual(state.update(candidate: first, at: validDeadline), .ready(first))
    }

    func testResetInvalidatesTimerGenerationAndAllowsIndependentNextDrag() {
        let target = LauncherDropTarget.pageInsertion(page: 1, index: 3)
        var state = LauncherDragIntentState()
        state.update(candidate: target, at: 0)
        let previousGeneration = state.generation

        state.reset()

        XCTAssertNil(state.candidate)
        XCTAssertNil(state.deadline)
        XCTAssertFalse(state.isReady)
        XCTAssertNotEqual(state.generation, previousGeneration)
        XCTAssertEqual(state.update(candidate: target, at: 1), .hold)
        XCTAssertEqual(state.beganAt, 1)
        XCTAssertNotEqual(state.generation, previousGeneration)
    }

    func testConfiguredDurationsApplyToCorrectIntentAndZeroDwellIsImmediate() throws {
        let merge = LauncherDropTarget.application(applicationIdentity("alpha"))
        let insertion = LauncherDropTarget.pageInsertion(page: 0, index: 1)
        var state = LauncherDragIntentState(mergeDwell: 0.8, reorderDwell: 0)

        XCTAssertEqual(state.update(candidate: insertion, at: 3), .ready(insertion))
        XCTAssertEqual(state.update(candidate: merge, at: 4), .hold)
        let deadline = try XCTUnwrap(state.deadline)
        XCTAssertEqual(deadline, 4.8, accuracy: 0.000_001)
        XCTAssertEqual(state.update(candidate: merge, at: deadline), .ready(merge))
    }

    private func applicationIdentity(_ name: String) -> ApplicationIdentity {
        ApplicationIdentity(
            bundleIdentifier: "org.example.\(name)",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app")
        )
    }
}
