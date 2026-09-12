@testable import AppCore
import Foundation
import XCTest

final class LauncherLayoutStoreTests: XCTestCase {
    func testMissingFileLoadsEmptyCurrentVersionDocument() async throws {
        let fileIO = MemoryLayoutFileIO()
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)

        let document = try await store.load()

        XCTAssertEqual(document, LauncherLayoutDocument())
        XCTAssertEqual(fileIO.writeCount, 0)
    }

    func testCommittedTransactionIncrementsRevisionAndCanBeReloaded() async throws {
        let fileIO = MemoryLayoutFileIO()
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)
        let application = reference("org.example.committed")

        let committed = try await store.transact(expectedRevision: 0) { document in
            document.items.append(.application(application))
            return .commit
        }
        let reloadedStore = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)
        let reloaded = try await reloadedStore.load()

        XCTAssertEqual(committed.revision, 1)
        XCTAssertEqual(committed.items, [.application(application)])
        XCTAssertEqual(reloaded, committed)
        XCTAssertEqual(fileIO.writeCount, 1)
    }

    func testCommitDraftUsesSnapshotRevisionAndPersistsPreview() async throws {
        let fileIO = MemoryLayoutFileIO()
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)
        let alpha = reference("org.example.alpha")
        let beta = reference("org.example.beta")
        _ = try await store.transact(expectedRevision: 0) { document in
            document.items = [.application(alpha), .application(beta)]
            return .commit
        }
        let snapshot = try await store.load()
        var draft = try LauncherLayoutDraft(document: snapshot)
        try draft.moveRootItem(from: 0, to: 1)

        let committed = try await store.commit(draft)

        XCTAssertEqual(committed.revision, 2)
        XCTAssertEqual(committed.items, [.application(beta), .application(alpha)])
        XCTAssertEqual(fileIO.writeCount, 2)
    }

    func testExplicitRollbackLeavesMemoryAndDiskUnchanged() async throws {
        let fileIO = MemoryLayoutFileIO()
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)
        let application = reference("org.example.cancelled")

        let result = try await store.transact(expectedRevision: 0) { document in
            document.items.append(.application(application))
            return .rollback
        }
        let current = try await store.load()

        XCTAssertEqual(result, LauncherLayoutDocument())
        XCTAssertEqual(current, LauncherLayoutDocument())
        XCTAssertEqual(fileIO.writeCount, 0)
    }

    func testThrownMutationRollsBack() async throws {
        let fileIO = MemoryLayoutFileIO()
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)
        let application = reference("org.example.failure")

        do {
            _ = try await store.transact(expectedRevision: 0) { document in
                document.items.append(.application(application))
                throw TestError.expected
            }
            XCTFail("Expected the transaction to throw")
        } catch TestError.expected {}

        let current = try await store.load()
        XCTAssertEqual(current, LauncherLayoutDocument())
        XCTAssertEqual(fileIO.writeCount, 0)
    }

    func testAtomicWriteFailureDoesNotPublishCandidateToMemory() async throws {
        let fileIO = MemoryLayoutFileIO(failsWrites: true)
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)
        let application = reference("org.example.failure")

        do {
            _ = try await store.transact(expectedRevision: 0) { document in
                document.items.append(.application(application))
                return .commit
            }
            XCTFail("Expected the write to throw")
        } catch TestError.expected {}

        let current = try await store.load()
        XCTAssertEqual(current, LauncherLayoutDocument())
        XCTAssertNil(fileIO.data)
    }

    func testStaleRevisionIsRejectedBeforeMutation() async throws {
        let fileIO = MemoryLayoutFileIO()
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)

        do {
            _ = try await store.transact(expectedRevision: 9) { _ in .commit }
            XCTFail("Expected a revision conflict")
        } catch let error as LauncherLayoutStoreError {
            XCTAssertEqual(error, .revisionConflict(expected: 9, actual: 0))
        }

        XCTAssertEqual(fileIO.writeCount, 0)
    }

    func testReconcileAndCommitPersistsNewApplicationsOnce() async throws {
        let fileIO = MemoryLayoutFileIO()
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)
        let application = ApplicationRecord(
            displayName: "New",
            bundleIdentifier: "org.example.new",
            bundleURL: URL(fileURLWithPath: "/Applications/New.app")
        )

        let first = try await store.reconcileAndCommit(applications: [application])
        let second = try await store.reconcileAndCommit(applications: [application])

        XCTAssertEqual(first.document.revision, 1)
        XCTAssertEqual(first.report.addedApplications, [application.id])
        XCTAssertEqual(second.document, first.document)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(fileIO.writeCount, 1)
    }

    func testResetReplacesFoldersAndPagesWithProvidedApplicationOrder() async throws {
        let fileIO = MemoryLayoutFileIO()
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)
        let alpha = application("Alpha")
        let beta = application("Beta")
        let folder = LauncherFolder(applications: [
            LauncherApplicationReference(application: alpha),
            LauncherApplicationReference(application: beta),
        ])
        _ = try await store.transact(expectedRevision: 0) { document in
            document.pages = [[], [.folder(folder)]]
            return .commit
        }

        let reset = try await store.reset(
            applications: [beta, alpha, beta],
            completeness: .complete
        )

        XCTAssertEqual(reset.revision, 2)
        XCTAssertEqual(reset.pages, [[
            .application(LauncherApplicationReference(application: beta)),
            .application(LauncherApplicationReference(application: alpha)),
        ]])
        XCTAssertEqual(fileIO.writeCount, 2)
    }

    func testResetRejectsPartialCatalogWithoutChangingLayout() async throws {
        let fileIO = MemoryLayoutFileIO()
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)
        let alpha = application("Alpha")
        _ = try await store.reconcileAndCommit(applications: [alpha])

        do {
            _ = try await store.reset(applications: [], completeness: .partial)
            XCTFail("Expected incomplete catalog reset to be rejected")
        } catch let error as LauncherLayoutStoreError {
            XCTAssertEqual(error, .incompleteCatalogForReset)
        }

        let unchanged = try await store.load()
        XCTAssertEqual(unchanged.items, [
            .application(LauncherApplicationReference(application: alpha)),
        ])
        XCTAssertEqual(fileIO.writeCount, 1)
    }

    func testResetOfAlreadyCanonicalLayoutDoesNotWriteAgain() async throws {
        let fileIO = MemoryLayoutFileIO()
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)
        let alpha = application("Alpha")
        let original = try await store.reset(applications: [alpha], completeness: .complete)

        let unchanged = try await store.reset(applications: [alpha], completeness: .complete)

        XCTAssertEqual(unchanged, original)
        XCTAssertEqual(fileIO.writeCount, 1)
    }

    func testSequentialMigrationIsPersistedWithoutChangingRevision() async throws {
        let legacy = LegacyLayoutDocument(
            schemaVersion: 0,
            revision: 4,
            applicationPaths: ["/Applications/Legacy.app"]
        )
        let fileIO = try MemoryLayoutFileIO(data: JSONEncoder().encode(legacy))
        let codec = LauncherLayoutCodec(migrations: [LegacyLayoutMigration()])
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO, codec: codec)

        let document = try await store.load()

        XCTAssertEqual(document.schemaVersion, 2)
        XCTAssertEqual(document.revision, 4)
        XCTAssertEqual(document.items, [
            .application(LauncherApplicationReference(identity: ApplicationIdentity.bundlePath(
                for: URL(fileURLWithPath: "/Applications/Legacy.app")
            ))),
        ])
        XCTAssertEqual(fileIO.writeCount, 1)
        let persistedData = try XCTUnwrap(fileIO.data)
        XCTAssertEqual(try LauncherLayoutCodec().decode(persistedData), document)
    }

    func testFutureSchemaIsRejectedWithoutOverwritingSourceData() async throws {
        let source = Data(#"{"schemaVersion":3,"revision":0,"pages":[[]]}"#.utf8)
        let fileIO = MemoryLayoutFileIO(data: source)
        let store = LauncherLayoutStore(fileURL: testURL, fileIO: fileIO)

        do {
            _ = try await store.load()
            XCTFail("Expected a future-schema error")
        } catch let error as LauncherLayoutCodingError {
            XCTAssertEqual(error, .unsupportedSchemaVersion(3))
        }

        XCTAssertEqual(fileIO.data, source)
        XCTAssertEqual(fileIO.writeCount, 0)
    }

    func testAtomicFileIOCreatesParentAndRoundTripsData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenLaunchpadLayoutStore-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("Nested/Layout.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileIO = AtomicLauncherLayoutFileIO()
        let expected = Data("layout".utf8)

        try fileIO.writeDataAtomically(expected, to: url)

        XCTAssertEqual(try fileIO.readData(at: url), expected)
    }

    private var testURL: URL {
        URL(fileURLWithPath: "/tests/OpenLaunchpad/LauncherLayout.json")
    }

    private func reference(_ bundleIdentifier: String) -> LauncherApplicationReference {
        LauncherApplicationReference(identity: ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            bundleURL: URL(fileURLWithPath: "/Applications/\(bundleIdentifier).app")
        ))
    }

    private func application(_ name: String) -> ApplicationRecord {
        ApplicationRecord(
            displayName: name,
            bundleIdentifier: "org.example.\(name.lowercased())",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app")
        )
    }
}

private enum TestError: Error {
    case expected
}

private final class MemoryLayoutFileIO: LauncherLayoutFileIO, @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?
    private var storedWriteCount = 0
    private let failsWrites: Bool

    init(data: Data? = nil, failsWrites: Bool = false) {
        storedData = data
        self.failsWrites = failsWrites
    }

    var data: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedWriteCount
    }

    func readData(at _: URL) throws -> Data? {
        data
    }

    func writeDataAtomically(_ data: Data, to _: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !failsWrites else { throw TestError.expected }
        storedData = data
        storedWriteCount += 1
    }
}

private struct LegacyLayoutDocument: Codable {
    let schemaVersion: Int
    let revision: UInt64
    let applicationPaths: [String]
}

private struct LegacyLayoutMigration: LauncherLayoutMigration {
    let sourceVersion = 0
    let destinationVersion = 1

    func migrate(_ data: Data) throws -> Data {
        let legacy = try JSONDecoder().decode(LegacyLayoutDocument.self, from: data)
        let items = legacy.applicationPaths.map { path in
            LauncherLayoutItem.application(LauncherApplicationReference(
                identity: ApplicationIdentity.bundlePath(for: URL(fileURLWithPath: path))
            ))
        }
        struct VersionOne: Encodable {
            let schemaVersion = 1
            let revision: UInt64
            let items: [LauncherLayoutItem]
        }
        return try JSONEncoder().encode(VersionOne(revision: legacy.revision, items: items))
    }
}
