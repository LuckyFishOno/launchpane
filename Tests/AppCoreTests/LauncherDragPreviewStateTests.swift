@testable import AppCore
import Foundation
import XCTest

final class LauncherDragPreviewStateTests: XCTestCase {
    func testInitialSourceDestinationDoesNotMaterializeDuplicatePreview() {
        let source = applicationItem("org.example.alpha")
        var state = LauncherDragPreviewState(source: source)

        XCTAssertEqual(state.request(destination: source), .none)
        XCTAssertFalse(state.isMaterialized)
        XCTAssertEqual(state.destination, source)
    }

    func testFirstRealMoveMaterializesPreview() {
        let source = applicationItem("org.example.alpha")
        let destination = applicationItem("org.example.beta")
        var state = LauncherDragPreviewState(source: source)

        XCTAssertEqual(state.request(destination: destination), .materialize)
        XCTAssertTrue(state.isMaterialized)
        XCTAssertEqual(state.destination, destination)
    }

    func testSubsequentMoveReflowsExistingPreviewWithoutRestartingDuplicates() {
        let source = applicationItem("org.example.alpha")
        let second = applicationItem("org.example.beta")
        let third = applicationItem("org.example.gamma")
        var state = LauncherDragPreviewState(source: source)

        XCTAssertEqual(state.request(destination: second), .materialize)
        XCTAssertEqual(state.request(destination: second), .none)
        XCTAssertEqual(state.request(destination: third), .reflow)
        XCTAssertEqual(state.request(destination: third), .none)
    }

    private func applicationItem(_ bundleIdentifier: String) -> LauncherLayoutItemIdentifier {
        .application(ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            bundleURL: URL(fileURLWithPath: "/Applications/\(bundleIdentifier).app")
        ))
    }
}
