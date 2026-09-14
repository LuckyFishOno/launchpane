@testable import AppCore
import Foundation
import XCTest

final class LauncherLayoutDraftTests: XCTestCase {
    func testMoveRootItemUsesFinalArrayIndex() throws {
        let alpha = reference("org.example.alpha")
        let beta = reference("org.example.beta")
        let canvas = reference("org.example.canvas")
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(items: [
            .application(alpha),
            .application(beta),
            .application(canvas),
        ]))

        try draft.moveRootItem(from: 0, to: 2)

        XCTAssertEqual(draft.document.items, [
            .application(beta),
            .application(canvas),
            .application(alpha),
        ])
        XCTAssertTrue(draft.hasChanges)
    }

    func testStableMoveDoesNotTreatVisibleIndexAsDocumentIndex() throws {
        let unavailable = reference("org.example.unavailable")
        let alpha = reference("org.example.alpha")
        let beta = reference("org.example.beta")
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(items: [
            .application(unavailable),
            .application(alpha),
            .application(beta),
        ]))

        // A partial catalog can project only [alpha, beta]. Moving alpha to beta's
        // visible position must not accidentally target document index 1 (alpha itself).
        try draft.moveRootItem(
            .application(alpha.identity),
            toPositionOf: .application(beta.identity)
        )

        XCTAssertEqual(draft.document.items, [
            .application(unavailable),
            .application(beta),
            .application(alpha),
        ])
    }

    func testStableMovePreservesUnresolvedReferenceBetweenVisibleItems() throws {
        let alpha = reference("org.example.alpha")
        let unavailable = reference("org.example.unavailable")
        let beta = reference("org.example.beta")
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(items: [
            .application(alpha),
            .application(unavailable),
            .application(beta),
        ]))

        try draft.moveRootItem(
            .application(beta.identity),
            toPositionOf: .application(alpha.identity)
        )

        XCTAssertEqual(draft.document.items, [
            .application(beta),
            .application(alpha),
            .application(unavailable),
        ])
    }

    func testStableMoveRejectsMissingVisibleDestinationWithoutPublishing() throws {
        let alpha = reference("org.example.alpha")
        let missing = reference("org.example.missing")
        let document = LauncherLayoutDocument(items: [.application(alpha)])
        var draft = try LauncherLayoutDraft(document: document)

        XCTAssertThrowsError(try draft.moveRootItem(
            .application(alpha.identity),
            toPositionOf: .application(missing.identity)
        )) { error in
            XCTAssertEqual(
                error as? LauncherLayoutMutationError,
                .layoutItemIsNotAtRoot(.application(missing.identity))
            )
        }
        XCTAssertEqual(draft.document, document)
    }

    func testMergeApplicationsReplacesTargetWithFolderAndPreservesChildOrder() throws {
        let alpha = reference("org.example.alpha")
        let beta = reference("org.example.beta")
        let canvas = reference("org.example.canvas")
        let folderID = try XCTUnwrap(UUID(uuidString: "60000000-0000-0000-0000-000000000001"))
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(items: [
            .application(alpha),
            .application(beta),
            .application(canvas),
        ]))

        try draft.mergeApplications(
            source: alpha.identity,
            target: canvas.identity,
            folderID: folderID,
            customTitle: "Tools"
        )

        XCTAssertEqual(draft.document.items, [
            .application(beta),
            .folder(LauncherFolder(
                id: folderID,
                customTitle: "Tools",
                applications: [canvas, alpha]
            )),
        ])
    }

    func testAddApplicationToFolderRecomputesFolderIndexAfterSourceRemoval() throws {
        let alpha = reference("org.example.alpha")
        let beta = reference("org.example.beta")
        let canvas = reference("org.example.canvas")
        let draw = reference("org.example.draw")
        let folderID = try XCTUnwrap(UUID(uuidString: "70000000-0000-0000-0000-000000000001"))
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(items: [
            .application(alpha),
            .folder(LauncherFolder(id: folderID, applications: [beta, canvas])),
            .application(draw),
        ]))

        try draft.addApplication(alpha.identity, toFolder: folderID, at: 1)

        XCTAssertEqual(draft.document.items, [
            .folder(LauncherFolder(id: folderID, applications: [beta, alpha, canvas])),
            .application(draw),
        ])
    }

    func testMoveApplicationWithinFolderUsesFinalChildPosition() throws {
        let alpha = reference("org.example.alpha")
        let beta = reference("org.example.beta")
        let canvas = reference("org.example.canvas")
        let draw = reference("org.example.draw")
        let folderID = try XCTUnwrap(UUID(uuidString: "71000000-0000-0000-0000-000000000001"))
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(items: [
            .folder(LauncherFolder(
                id: folderID,
                applications: [alpha, beta, canvas, draw]
            )),
        ]))

        try draft.moveApplication(
            alpha.identity,
            inFolder: folderID,
            toPositionOf: canvas.identity
        )

        guard case let .folder(folder) = draft.document.items[0] else {
            return XCTFail("Expected folder")
        }
        XCTAssertEqual(folder.applications, [beta, canvas, alpha, draw])
    }

    func testMoveApplicationWithinFolderSupportsBackwardMove() throws {
        let alpha = reference("org.example.alpha")
        let beta = reference("org.example.beta")
        let canvas = reference("org.example.canvas")
        let folderID = try XCTUnwrap(UUID(uuidString: "71000000-0000-0000-0000-000000000002"))
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(items: [
            .folder(LauncherFolder(id: folderID, applications: [alpha, beta, canvas])),
        ]))

        try draft.moveApplication(
            canvas.identity,
            inFolder: folderID,
            toPositionOf: alpha.identity
        )

        guard case let .folder(folder) = draft.document.items[0] else {
            return XCTFail("Expected folder")
        }
        XCTAssertEqual(folder.applications, [canvas, alpha, beta])
    }

    // OPENLAUNCHPAD_FOLDER_DRAG_ROOT_PARITY_V19
    func testMoveApplicationWithinFolderToExactIndexMatchesProjectedSlot() throws {
        let alpha = reference("org.example.alpha")
        let beta = reference("org.example.beta")
        let canvas = reference("org.example.canvas")
        let draw = reference("org.example.draw")
        let folderID = try XCTUnwrap(UUID(uuidString: "71000000-0000-0000-0000-000000000003"))
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(items: [
            .folder(LauncherFolder(
                id: folderID,
                applications: [alpha, beta, canvas, draw]
            )),
        ]))

        try draft.moveApplication(alpha.identity, inFolder: folderID, toIndex: 2)

        guard case let .folder(folder) = draft.document.items[0] else {
            return XCTFail("Expected folder")
        }
        XCTAssertEqual(folder.applications, [beta, canvas, alpha, draw])
    }

    func testMoveApplicationWithinFolderExactIndexSupportsAppendAfterRemoval() throws {
        let alpha = reference("org.example.alpha")
        let beta = reference("org.example.beta")
        let canvas = reference("org.example.canvas")
        let folderID = try XCTUnwrap(UUID(uuidString: "71000000-0000-0000-0000-000000000004"))
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(items: [
            .folder(LauncherFolder(id: folderID, applications: [alpha, beta, canvas])),
        ]))

        try draft.moveApplication(alpha.identity, inFolder: folderID, toIndex: 2)

        guard case let .folder(folder) = draft.document.items[0] else {
            return XCTFail("Expected folder")
        }
        XCTAssertEqual(folder.applications, [beta, canvas, alpha])
    }

    func testRollbackRestoresSnapshotAndClosesDraft() throws {
        let alpha = reference("org.example.alpha")
        let beta = reference("org.example.beta")
        let original = LauncherLayoutDocument(items: [.application(alpha), .application(beta)])
        var draft = try LauncherLayoutDraft(document: original)
        try draft.moveRootItem(from: 0, to: 1)

        draft.rollback()

        XCTAssertEqual(draft.document, original)
        XCTAssertEqual(draft.state, .rolledBack)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertThrowsError(try draft.moveRootItem(from: 0, to: 1)) { error in
            XCTAssertEqual(error as? LauncherLayoutMutationError, .draftIsRolledBack)
        }
    }

    func testFailedMutationDoesNotPublishPartialCandidate() throws {
        let alpha = reference("org.example.alpha")
        let beta = reference("org.example.beta")
        let document = LauncherLayoutDocument(items: [.application(alpha), .application(beta)])
        let missingFolderID = try XCTUnwrap(
            UUID(uuidString: "80000000-0000-0000-0000-000000000001")
        )
        var draft = try LauncherLayoutDraft(document: document)

        XCTAssertThrowsError(
            try draft.addApplication(alpha.identity, toFolder: missingFolderID)
        ) { error in
            XCTAssertEqual(
                error as? LauncherLayoutMutationError,
                .folderNotFound(missingFolderID)
            )
        }
        XCTAssertEqual(draft.document, document)
    }

    private func reference(_ bundleIdentifier: String) -> LauncherApplicationReference {
        LauncherApplicationReference(identity: ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            bundleURL: URL(fileURLWithPath: "/Applications/\(bundleIdentifier).app")
        ))
    }
}
