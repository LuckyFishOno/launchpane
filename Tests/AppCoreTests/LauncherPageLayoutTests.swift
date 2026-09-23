@testable import AppCore
import Foundation
import XCTest

final class LauncherPageLayoutTests: XCTestCase {
    func testLegacyFlatDocumentMigratesWithoutGuessingCapacityOrChangingRevision() throws {
        let original = LegacyPageLayout(revision: 9, items: page("ABCDEFG"))
        let decoded = try LauncherLayoutCodec().decode(JSONEncoder().encode(original))
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.revision, 9)
        XCTAssertEqual(decoded.pages, [page("ABCDEFG")])
        XCTAssertEqual(decoded.normalizedForPageCapacity(3).pages, pages("ABC", "DEF", "G"))
    }

    func testRoundTripPreservesEmptyInteriorPageAndIntentionalVacancies() throws {
        let original = LauncherLayoutDocument(revision: 12, pages: pages("AB", "", "C", "DE"))
        let codec = LauncherLayoutCodec()
        let decoded = try codec.decode(codec.encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.normalizedForPageCapacity(4), original)
    }

    func testNormalizationOnlyCascadesForwardOverflowAndIsIdempotent() {
        let original = LauncherLayoutDocument(pages: pages("A", "BCDE", "FGH", "I"))
        let result = original.normalizedForPageCapacity(3)
        XCTAssertEqual(result.pages, pages("A", "BCD", "EFG", "HI"))
        XCTAssertEqual(result.normalizedForPageCapacity(3), result)
        XCTAssertEqual(result.items, original.items)
    }

    func testLargerCapacityNeverPullsItemsBackIntoPreviousPages() {
        let original = LauncherLayoutDocument(pages: pages("A", "BC", "DE"))
        XCTAssertEqual(original.normalizedForPageCapacity(8), original)
    }

    func testMoveAcrossSeveralPagesKeepsSourceVacancyAndIntermediatePages() throws {
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(
            pages: pages("AB", "CD", "EF", "G")
        ))
        try draft.moveRootItem(identifier("B"), toPage: 3, at: 1, pageCapacity: 2)
        XCTAssertEqual(draft.document.pages, pages("A", "CD", "EF", "GB"))
    }

    func testMoveIntoFullPagePushesOverflowForwardAndCreatesPage() throws {
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(
            pages: pages("ABCD", "EFGH", "IJKL")
        ))
        try draft.moveRootItem(identifier("B"), toPage: 1, at: 1, pageCapacity: 4)
        XCTAssertEqual(draft.document.pages, pages("ACD", "EBFG", "HIJK", "L"))
        XCTAssertEqual(draft.document.items.count, 12)
    }

    func testReverseMovePushesOnlyForwardTowardTheSourceVacancy() throws {
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(
            pages: pages("AB", "CD", "EF", "GH")
        ))
        try draft.moveRootItem(identifier("H"), toPage: 0, at: 1, pageCapacity: 2)
        XCTAssertEqual(draft.document.pages, pages("AH", "BC", "DE", "FG"))
    }

    func testEmptySourcePageDoesNotPullItemsFromFollowingPage() throws {
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(pages: pages("A", "BC", "D")))
        try draft.moveRootItem(identifier("A"), toPage: 2, at: 1, pageCapacity: 3)
        XCTAssertEqual(draft.document.pages, pages("", "BC", "DA"))
    }

    func testSamePageMoveUsesFinalLocalIndexAndDoesNotTouchOtherPages() throws {
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(pages: pages("ABC", "D", "EF")))
        try draft.moveRootItem(identifier("A"), toPage: 0, at: 2, pageCapacity: 3)
        XCTAssertEqual(draft.document.pages, pages("BCA", "D", "EF"))
    }

    func testCreatingNextPageIsChangeEvenWhenFlatOrderStaysIdentical() throws {
        let original = LauncherLayoutDocument(pages: pages("AB"))
        var draft = try LauncherLayoutDraft(document: original)
        try draft.moveRootItem(identifier("B"), toPage: 1, at: 0, pageCapacity: 3)
        XCTAssertEqual(draft.document.pages, pages("A", "B"))
        XCTAssertEqual(draft.document.items, original.items)
        XCTAssertTrue(draft.hasChanges)
    }

    func testInvalidDestinationDoesNotPublishSourceRemoval() throws {
        let original = LauncherLayoutDocument(pages: pages("AB", "CD"))
        var draft = try LauncherLayoutDraft(document: original)
        XCTAssertThrowsError(try draft.moveRootItem(identifier("B"), toPage: 1, at: 5, pageCapacity: 3))
        XCTAssertThrowsError(try draft.moveRootItem(identifier("B"), toPage: 3, at: 0, pageCapacity: 3))
        XCTAssertThrowsError(try draft.moveRootItem(identifier("B"), toPage: 1, at: 0, pageCapacity: 0))
        XCTAssertThrowsError(try draft.moveRootItem(identifier("Z"), toPage: 1, at: 0, pageCapacity: 3))
        XCTAssertEqual(draft.document, original)
    }

    func testFolderMergeKeepsFolderOnTargetPageAndSourcePageGap() throws {
        var draft = try LauncherLayoutDraft(document: LauncherLayoutDocument(pages: pages("AB", "CD", "EF")))
        let folderID = UUID()
        try draft.mergeApplications(
            source: reference("A").identity, target: reference("E").identity, folderID: folderID
        )
        XCTAssertEqual(draft.document.pages, [page("B"), page("CD"), [
            .folder(LauncherFolder(id: folderID, applications: [reference("E"), reference("A")])),
            .application(reference("F")),
        ]])
    }

    func testAddingToFolderDoesNotShiftUnrelatedPages() throws {
        let folder = LauncherFolder(applications: [reference("C"), reference("D")])
        var draft = try LauncherLayoutDraft(
            document: LauncherLayoutDocument(pages: [page("AB"), [.folder(folder)], page("EF")])
        )
        try draft.addApplication(reference("B").identity, toFolder: folder.id)
        XCTAssertEqual(draft.document.pages, [page("A"), [
            .folder(LauncherFolder(id: folder.id, applications: [reference("C"), reference("D"), reference("B")])),
        ], page("EF")])
    }

    func testRootFolderCanMoveAcrossPagesAndOverflowAsOneItem() throws {
        let folder = LauncherFolder(applications: [reference("X"), reference("Y")])
        var draft = try LauncherLayoutDraft(
            document: LauncherLayoutDocument(pages: [[.folder(folder)], page("AB"), page("CD")])
        )
        try draft.moveRootItem(.folder(folder.id), toPage: 2, at: 1, pageCapacity: 2)
        XCTAssertEqual(
            draft.document.pages, [[], page("AB"), [.application(reference("C")), .folder(folder)], page("D")]
        )
    }

    func testReconcilePrunesWithinPageAndAppendsNewAppsOnlyAtEnd() {
        let original = LauncherLayoutDocument(pages: pages("AB", "CD", "E"))
        let result = LauncherLayoutReconciler.reconcile(original, with: "BCDEF".map { application(String($0)) })
        XCTAssertEqual(result.document.pages, pages("B", "CD", "EF"))
        XCTAssertEqual(result.document.normalizedForPageCapacity(2).pages, pages("B", "CD", "EF"))
    }

    func testReconcileFolderDissolvesOnSamePageWithoutFillingEarlierGap() {
        let folder = LauncherFolder(applications: [reference("C"), reference("D")])
        let original = LauncherLayoutDocument(pages: [page("A"), [.folder(folder)], page("E")])
        let result = LauncherLayoutReconciler.reconcile(original, with: "ACE".map { application(String($0)) })
        XCTAssertEqual(result.document.pages, pages("A", "C", "E"))
    }

    func testPartialCatalogRetainsUnavailableReferenceOnItsOriginalPage() {
        let original = LauncherLayoutDocument(pages: pages("A", "B", "C"))
        let result = LauncherLayoutReconciler.reconcile(
            original, with: [application("A"), application("C")], completeness: .partial
        )
        XCTAssertEqual(result.document, original)
    }

    func testStorePersistsPageBoundaryOnlyChangeAndReloadsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PageLayout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Layout.json")
        let store = LauncherLayoutStore(fileURL: url)
        let initialPages = pages("AB")
        let original = try await store.transact(expectedRevision: 0) { document in
            document.pages = initialPages
            return .commit
        }
        var draft = try LauncherLayoutDraft(document: original)
        try draft.moveRootItem(identifier("B"), toPage: 1, at: 0, pageCapacity: 3)
        let committed = try await store.commit(draft)
        let reloaded = try await LauncherLayoutStore(fileURL: url).load()
        XCTAssertEqual(committed.revision, 2)
        XCTAssertEqual(reloaded.pages, pages("A", "B"))
        XCTAssertEqual(reloaded.items, original.items)
    }

    func testMigrationBacksUpOriginalBytesAndDoesNotOverwriteExistingBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PageMigration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Layout.json")
        let backupURL = root.appendingPathComponent("Layout.pre-pages.backup.json")
        let originalData = try JSONEncoder().encode(LegacyPageLayout(revision: 7, items: page("ABC")))
        let fileIO = AtomicLauncherLayoutFileIO()
        try fileIO.writeDataAtomically(originalData, to: url)
        let migrated = try await LauncherLayoutStore(fileURL: url).load()
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.revision, 7)
        XCTAssertEqual(try Data(contentsOf: backupURL), originalData)
        XCTAssertEqual(try LauncherLayoutCodec().decode(Data(contentsOf: url)), migrated)
        try fileIO.preservePreMigrationData(Data("replacement".utf8), at: url)
        XCTAssertEqual(try Data(contentsOf: backupURL), originalData)
    }

    private func pages(_ letters: String...) -> [[LauncherLayoutItem]] { letters.map(page) }
    private func page(_ letters: String) -> [LauncherLayoutItem] { letters.map { .application(reference(String($0))) } }
    private func identifier(_ letter: String) -> LauncherLayoutItemIdentifier {
        .application(reference(letter).identity)
    }
    private func reference(_ letter: String) -> LauncherApplicationReference {
        LauncherApplicationReference(application: application(letter))
    }
    private func application(_ letter: String) -> ApplicationRecord {
        ApplicationRecord(
            displayName: letter, bundleIdentifier: "org.test.\(letter)",
            bundleURL: URL(fileURLWithPath: "/Applications/\(letter).app")
        )
    }
}

private struct LegacyPageLayout: Encodable {
    let schemaVersion = 1
    let revision: UInt64
    let items: [LauncherLayoutItem]
}
