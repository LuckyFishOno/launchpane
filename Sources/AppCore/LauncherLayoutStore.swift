import Foundation

public protocol LauncherLayoutMigration: Sendable {
    var sourceVersion: Int { get }
    var destinationVersion: Int { get }

    func migrate(_ data: Data) throws -> Data
}

public enum LauncherLayoutCodingError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case missingMigration(fromVersion: Int)
    case invalidMigrationStep(sourceVersion: Int, expectedVersion: Int, actualVersion: Int)
}

public struct LauncherLayoutCodec: Sendable {
    private struct Header: Decodable {
        let schemaVersion: Int
    }

    struct DecodedDocument: Sendable {
        let document: LauncherLayoutDocument
        let wasMigrated: Bool
    }

    private let migrationsBySourceVersion: [Int: any LauncherLayoutMigration]

    public init(migrations: [any LauncherLayoutMigration] = []) {
        var indexedMigrations: [Int: any LauncherLayoutMigration] = [1: PageLayoutMigration()]
        for migration in migrations where indexedMigrations[migration.sourceVersion] == nil {
            indexedMigrations[migration.sourceVersion] = migration
        }
        migrationsBySourceVersion = indexedMigrations
    }

    public func decode(_ data: Data) throws -> LauncherLayoutDocument {
        try decodeDocument(data).document
    }

    public func encode(_ document: LauncherLayoutDocument) throws -> Data {
        try LauncherLayoutValidator.validate(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    func decodeDocument(_ originalData: Data) throws -> DecodedDocument {
        let decoder = JSONDecoder()
        var data = originalData
        var version = try decoder.decode(Header.self, from: data).schemaVersion
        let currentVersion = LauncherLayoutDocument.currentSchemaVersion

        guard version <= currentVersion else {
            throw LauncherLayoutCodingError.unsupportedSchemaVersion(version)
        }

        var wasMigrated = false
        while version < currentVersion {
            guard let migration = migrationsBySourceVersion[version] else {
                throw LauncherLayoutCodingError.missingMigration(fromVersion: version)
            }
            let expectedVersion = version + 1
            guard migration.destinationVersion == expectedVersion else {
                throw LauncherLayoutCodingError.invalidMigrationStep(
                    sourceVersion: version,
                    expectedVersion: expectedVersion,
                    actualVersion: migration.destinationVersion
                )
            }

            data = try migration.migrate(data)
            let migratedVersion = try decoder.decode(Header.self, from: data).schemaVersion
            guard migratedVersion == expectedVersion else {
                throw LauncherLayoutCodingError.invalidMigrationStep(
                    sourceVersion: version,
                    expectedVersion: expectedVersion,
                    actualVersion: migratedVersion
                )
            }
            version = migratedVersion
            wasMigrated = true
        }

        let document = try decoder.decode(LauncherLayoutDocument.self, from: data)
        try LauncherLayoutValidator.validate(document)
        return DecodedDocument(document: document, wasMigrated: wasMigrated)
    }
}

public protocol LauncherLayoutFileIO: Sendable {
    func readData(at url: URL) throws -> Data?
    func writeDataAtomically(_ data: Data, to url: URL) throws
    func preservePreMigrationData(_ data: Data, at url: URL) throws
}

public extension LauncherLayoutFileIO {
    /// Custom/in-memory stores may supply their own backup policy.
    func preservePreMigrationData(_: Data, at _: URL) throws {}
}

public struct AtomicLauncherLayoutFileIO: LauncherLayoutFileIO {
    public init() {}

    public func readData(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func writeDataAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public func preservePreMigrationData(_ data: Data, at url: URL) throws {
        let backupURL = url.deletingPathExtension()
            .appendingPathExtension("pre-pages.backup.json")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        do {
            try data.write(to: backupURL, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Another reader already preserved the original. Never replace it.
        }
    }
}

public enum LauncherLayoutTransactionDisposition: Sendable {
    case commit
    case rollback
}

public enum LauncherLayoutStoreError: Error, Equatable, Sendable {
    case revisionConflict(expected: UInt64, actual: UInt64)
    case revisionOverflow
}

public actor LauncherLayoutStore {
    public nonisolated let fileURL: URL

    private let fileIO: any LauncherLayoutFileIO
    private let codec: LauncherLayoutCodec
    private var cachedDocument: LauncherLayoutDocument?

    public init(
        fileURL: URL = LauncherLayoutStore.defaultFileURL,
        fileIO: any LauncherLayoutFileIO = AtomicLauncherLayoutFileIO(),
        codec: LauncherLayoutCodec = LauncherLayoutCodec()
    ) {
        self.fileURL = fileURL
        self.fileIO = fileIO
        self.codec = codec
    }

    public nonisolated static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("OpenLaunchpad", isDirectory: true)
            .appendingPathComponent("LauncherLayout.json", isDirectory: false)
    }

    public func load() throws -> LauncherLayoutDocument {
        if let cachedDocument {
            return cachedDocument
        }

        guard let data = try fileIO.readData(at: fileURL) else {
            let document = LauncherLayoutDocument()
            cachedDocument = document
            return document
        }

        let decoded = try codec.decodeDocument(data)
        if decoded.wasMigrated {
            try fileIO.preservePreMigrationData(data, at: fileURL)
            try fileIO.writeDataAtomically(codec.encode(decoded.document), to: fileURL)
        }
        cachedDocument = decoded.document
        return decoded.document
    }

    @discardableResult
    public func reload() throws -> LauncherLayoutDocument {
        cachedDocument = nil
        return try load()
    }

    public func transact(
        expectedRevision: UInt64,
        _ mutation: @Sendable (inout LauncherLayoutDocument) throws -> LauncherLayoutTransactionDisposition
    ) throws -> LauncherLayoutDocument {
        let currentDocument = try load()
        guard currentDocument.revision == expectedRevision else {
            throw LauncherLayoutStoreError.revisionConflict(
                expected: expectedRevision,
                actual: currentDocument.revision
            )
        }

        var candidate = currentDocument
        let disposition = try mutation(&candidate)
        guard disposition == .commit, candidate.pages != currentDocument.pages else {
            return currentDocument
        }

        return try commit(candidate, replacing: currentDocument)
    }

    public func commit(_ draft: LauncherLayoutDraft) throws -> LauncherLayoutDocument {
        let currentDocument = try load()
        guard currentDocument.revision == draft.snapshot.revision else {
            throw LauncherLayoutStoreError.revisionConflict(
                expected: draft.snapshot.revision,
                actual: currentDocument.revision
            )
        }
        guard draft.state == .active, draft.hasChanges else {
            return currentDocument
        }
        return try commit(draft.document, replacing: currentDocument)
    }

    public func reconcileAndCommit(
        applications: [ApplicationRecord],
        completeness: LauncherCatalogCompleteness = .complete
    ) throws -> LauncherLayoutReconciliationResult {
        let currentDocument = try load()
        let reconciliation = LauncherLayoutReconciler.reconcile(
            currentDocument,
            with: applications,
            completeness: completeness
        )
        guard reconciliation.document.pages != currentDocument.pages else {
            return LauncherLayoutReconciliationResult(
                document: currentDocument,
                report: reconciliation.report
            )
        }

        let committedDocument = try commit(reconciliation.document, replacing: currentDocument)
        return LauncherLayoutReconciliationResult(
            document: committedDocument,
            report: reconciliation.report
        )
    }

    private func commit(
        _ candidate: LauncherLayoutDocument,
        replacing currentDocument: LauncherLayoutDocument
    ) throws -> LauncherLayoutDocument {
        let (nextRevision, overflow) = currentDocument.revision.addingReportingOverflow(1)
        guard !overflow else {
            throw LauncherLayoutStoreError.revisionOverflow
        }

        var committedDocument = candidate
        committedDocument.setRevision(nextRevision)
        try LauncherLayoutValidator.validate(committedDocument)
        let data = try codec.encode(committedDocument)
        try fileIO.writeDataAtomically(data, to: fileURL)
        cachedDocument = committedDocument
        return committedDocument
    }
}

/// The former flat order is retained as one logical page; actual display
/// capacity is applied later by normalizedForPageCapacity, never guessed here.
private struct PageLayoutMigration: LauncherLayoutMigration {
    let sourceVersion = 1
    let destinationVersion = 2

    func migrate(_ data: Data) throws -> Data {
        let document = try JSONDecoder().decode(LauncherLayoutDocument.self, from: data)
        return try JSONEncoder().encode(document)
    }
}
