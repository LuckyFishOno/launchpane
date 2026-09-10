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
