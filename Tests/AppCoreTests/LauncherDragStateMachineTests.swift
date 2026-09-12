@testable import AppCore
import Foundation
import XCTest

final class LauncherDragStateMachineTests: XCTestCase {
    func testClickPathNeverEntersDragging() {
        var machine = LauncherDragStateMachine()
        let item = applicationItem("org.example.alpha")

        XCTAssertTrue(machine.pointerDown(on: item))
        XCTAssertEqual(machine.state, .pressed(item))
        machine.finish()

        XCTAssertEqual(machine.state, .idle)
    }

    func testDragCommitRequiresAValidDropTarget() {
        var machine = LauncherDragStateMachine()
        let item = applicationItem("org.example.alpha")
        XCTAssertTrue(machine.pointerDown(on: item))
        XCTAssertTrue(machine.beginDragging())

        XCTAssertFalse(machine.beginCommit())
        XCTAssertTrue(machine.update(target: .insertion(destination: applicationItem("org.example.beta"))))
        XCTAssertTrue(machine.beginCommit())
        XCTAssertEqual(machine.state, .committing(item))
    }

    func testCommitCanEnterRollbackWhenPersistenceFails() {
        var machine = LauncherDragStateMachine()
        let source = applicationItem("org.example.alpha")
        let destination = applicationItem("org.example.beta")

        XCTAssertTrue(machine.pointerDown(on: source))
        XCTAssertTrue(machine.beginDragging())
        XCTAssertTrue(machine.update(target: .insertion(destination: destination)))
        XCTAssertTrue(machine.beginCommit())
        XCTAssertTrue(machine.beginRollback())
        XCTAssertEqual(machine.state, .rollingBack(source))

        machine.finish()
        XCTAssertEqual(machine.state, .idle)
    }

    func testPageLocalInsertionIsAcceptedForCommit() {
        var machine = LauncherDragStateMachine()
        let source = applicationItem("org.example.page-source")
        let target = LauncherDropTarget.pageInsertion(page: 3, index: 2)
        XCTAssertTrue(target.isInsertion)
        XCTAssertTrue(machine.pointerDown(on: source))
        XCTAssertTrue(machine.beginDragging())
        XCTAssertTrue(machine.update(target: target))
        XCTAssertEqual(machine.state, .dragging(source, target: target))
        XCTAssertTrue(machine.beginCommit())
        XCTAssertEqual(machine.state, .committing(source))
        XCTAssertFalse(machine.beginCommit(), "Mouse-up must not commit the same drag twice.")
    }

    func testReachedPageTargetReplacesOutsideAndCanAdvanceAcrossSeveralPages() {
        var machine = LauncherDragStateMachine()
        let source = applicationItem("org.example.edge-source")
        machine.pointerDown(on: source)
        machine.beginDragging()
        XCTAssertTrue(machine.update(target: .outside))
        XCTAssertFalse(machine.beginCommit())

        for page in [1, 2, 3, 2, 1, 0] {
            let target = LauncherDropTarget.pageInsertion(page: page, index: 0)
            XCTAssertTrue(machine.update(target: target))
            XCTAssertEqual(machine.state, .dragging(source, target: target))
        }
        XCTAssertTrue(machine.beginCommit(), "A valid edge landing must replace the old outside target.")
        XCTAssertEqual(machine.state, .committing(source))
    }

    func testCancelledPageInsertionRejectsLateTargetUpdatesAndCommit() {
        var machine = LauncherDragStateMachine()
        let source = applicationItem("org.example.cancelled-page-source")
        machine.pointerDown(on: source)
        machine.beginDragging()
        machine.update(target: .pageInsertion(page: 2, index: 0))

        XCTAssertTrue(machine.beginRollback())
        XCTAssertEqual(machine.state, .rollingBack(source))
        XCTAssertFalse(machine.update(target: .pageInsertion(page: 3, index: 0)))
        XCTAssertFalse(machine.beginCommit())
        machine.finish()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertFalse(machine.update(target: .pageInsertion(page: 3, index: 0)))
    }

    func testPageInsertionCommitCanRollbackWhenPersistenceFails() {
        var machine = LauncherDragStateMachine()
        let source = applicationItem("org.example.failed-page-source")
        machine.pointerDown(on: source)
        machine.beginDragging()
        machine.update(target: .pageInsertion(page: 1, index: 4))
        XCTAssertTrue(machine.beginCommit())
        XCTAssertTrue(machine.beginRollback())
        XCTAssertEqual(machine.state, .rollingBack(source))
        machine.finish()
        XCTAssertTrue(machine.pointerDown(on: source), "Rollback must leave the next drag usable.")
    }

    func testCancellationUsesExplicitRollbackState() {
        var machine = LauncherDragStateMachine()
        let item = applicationItem("org.example.alpha")
        machine.pointerDown(on: item)
        machine.beginDragging()
        machine.update(target: .folder(UUID()))

        XCTAssertTrue(machine.beginRollback())
        XCTAssertEqual(machine.state, .rollingBack(item))
        machine.finish()
        XCTAssertEqual(machine.state, .idle)
    }

    func testSecondPointerCannotReplaceActiveSession() {
        var machine = LauncherDragStateMachine()
        let first = applicationItem("org.example.first")
        let second = applicationItem("org.example.second")

        XCTAssertTrue(machine.pointerDown(on: first))
        XCTAssertFalse(machine.pointerDown(on: second))
        XCTAssertEqual(machine.state, .pressed(first))
    }

    private func applicationItem(_ bundleIdentifier: String) -> LauncherLayoutItemIdentifier {
        .application(ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            bundleURL: URL(fileURLWithPath: "/Applications/\(bundleIdentifier).app")
        ))
    }
}
