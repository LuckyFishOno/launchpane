@testable import AppCore
import Foundation
import XCTest

final class LauncherLayoutReconcilerTests: XCTestCase {
    func testReconcilePreservesPlacedOrderAndAppendsNewAppsInCatalogOrder() throws {
        let alpha = application("Alpha", identifier: "org.example.alpha")
        let beta = application("Beta", identifier: "org.example.beta")
        let canvas = application("Canvas", identifier: "org.example.canvas")
        let draw = application("Draw", identifier: "org.example.draw")
        let folderID = try XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
        let document = LauncherLayoutDocument(items: [
            .application(reference(beta)),
            .folder(LauncherFolder(
                id: folderID,
                customTitle: "Creative",
                applications: [reference(draw), reference(alpha)]
            )),
        ])

        let result = LauncherLayoutReconciler.reconcile(
            document,
            with: [alpha, beta, canvas, draw]
        )

        XCTAssertEqual(result.document.items, [
            .application(reference(beta)),
            .folder(LauncherFolder(
                id: folderID,
                customTitle: "Creative",
                applications: [reference(draw), reference(alpha)]
            )),
            .application(reference(canvas)),
        ])
        XCTAssertEqual(result.report.addedApplications, [canvas.id])
    }

    func testCompleteReconcilePrunesMissingAppsAndCollapsesFoldersInPlace() throws {
        let alpha = application("Alpha", identifier: "org.example.alpha")
        let beta = application("Beta", identifier: "org.example.beta")
        let missingOne = application("Missing One", identifier: "org.example.missing-one")
        let missingTwo = application("Missing Two", identifier: "org.example.missing-two")
        let missingThree = application("Missing Three", identifier: "org.example.missing-three")
        let dissolvingFolderID = try XCTUnwrap(
            UUID(uuidString: "20000000-0000-0000-0000-000000000001")
        )
        let emptyFolderID = try XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000002"))
        let document = LauncherLayoutDocument(items: [
            .folder(LauncherFolder(
                id: dissolvingFolderID,
                applications: [reference(alpha), reference(missingOne)]
            )),
            .folder(LauncherFolder(
                id: emptyFolderID,
                applications: [reference(missingTwo), reference(missingThree)]
            )),
            .application(reference(beta)),
        ])

        let result = LauncherLayoutReconciler.reconcile(document, with: [alpha, beta])

        XCTAssertEqual(result.document.items, [
            .application(reference(alpha)),
            .application(reference(beta)),
        ])
        XCTAssertEqual(result.report.dissolvedFolders, [dissolvingFolderID])
        XCTAssertEqual(result.report.removedFolders, [emptyFolderID])
        XCTAssertEqual(
            Set(result.report.removedApplications),
            Set([missingOne.id, missingTwo.id, missingThree.id])
        )
    }

    func testPartialReconcileRetainsUnresolvedReferencesAndFolderShape() throws {
        let installed = application("Installed", identifier: "org.example.installed")
        let unavailable = application("Unavailable", identifier: "org.example.unavailable")
        let folderID = try XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000001"))
        let folder = LauncherFolder(
            id: folderID,
            applications: [reference(installed), reference(unavailable)]
        )
        let document = LauncherLayoutDocument(items: [.folder(folder)])

        let result = LauncherLayoutReconciler.reconcile(
            document,
            with: [installed],
            completeness: .partial
        )

        XCTAssertEqual(result.document, document)
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.report.removedApplications.isEmpty)
    }

    func testLegacyPathReferenceCanonicalizesToBundleIdentifierWithoutMoving() {
        let installed = application(
            "Editor",
            identifier: "org.example.editor",
            path: "/Applications/Editor.app"
        )
        let pathIdentity = ApplicationIdentity.bundlePath(for: installed.bundleURL)
        let document = LauncherLayoutDocument(items: [
            .application(LauncherApplicationReference(identity: pathIdentity)),
        ])

        let result = LauncherLayoutReconciler.reconcile(document, with: [installed])

        XCTAssertEqual(result.document.items, [.application(reference(installed))])
        XCTAssertEqual(result.report.canonicalizedApplications, [LauncherIdentityCanonicalization(
            previous: pathIdentity,
            current: installed.id
        )])
        XCTAssertTrue(result.report.addedApplications.isEmpty)
    }

    func testReconcileDropsDuplicateAtLaterLocationAndIsIdempotent() throws {
        let alpha = application("Alpha", identifier: "org.example.alpha")
        let beta = application("Beta", identifier: "org.example.beta")
        let folderID = try XCTUnwrap(UUID(uuidString: "50000000-0000-0000-0000-000000000001"))
        let document = LauncherLayoutDocument(items: [
            .application(reference(alpha)),
            .folder(LauncherFolder(
                id: folderID,
                applications: [reference(alpha), reference(beta)]
            )),
        ])

        let first = LauncherLayoutReconciler.reconcile(document, with: [alpha, beta])
        let second = LauncherLayoutReconciler.reconcile(first.document, with: [alpha, beta])

        XCTAssertEqual(first.document.items, [
            .application(reference(alpha)),
            .application(reference(beta)),
        ])
        XCTAssertEqual(first.report.deduplicatedApplications, [alpha.id])
        XCTAssertEqual(first.report.dissolvedFolders, [folderID])
        XCTAssertEqual(second.document, first.document)
        XCTAssertFalse(second.changed)
    }

    func testReinstallWithSameBundleIdentifierKeepsOriginalPlacement() {
        let original = application(
            "Old Name",
            identifier: "org.example.stable",
            path: "/Applications/Old.app"
        )
        let reinstalled = application(
            "New Name",
            identifier: "ORG.EXAMPLE.STABLE",
            path: "/Users/test/Applications/New.app"
        )
        let document = LauncherLayoutDocument(items: [.application(reference(original))])

        let result = LauncherLayoutReconciler.reconcile(document, with: [reinstalled])

        XCTAssertEqual(result.document, document)
        XCTAssertFalse(result.changed)
    }

    private func application(
        _ name: String,
        identifier: String,
        path: String? = nil
    ) -> ApplicationRecord {
        ApplicationRecord(
            displayName: name,
            bundleIdentifier: identifier,
            bundleURL: URL(fileURLWithPath: path ?? "/Applications/\(name).app")
        )
    }

    private func reference(_ application: ApplicationRecord) -> LauncherApplicationReference {
        LauncherApplicationReference(application: application)
    }
}
