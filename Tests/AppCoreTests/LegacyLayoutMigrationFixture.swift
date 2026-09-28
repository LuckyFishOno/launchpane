import AppCore
import Foundation

struct LegacyLayoutDocument: Codable {
    let schemaVersion: Int
    let revision: UInt64
    let applicationPaths: [String]
}

struct LegacyLayoutMigration: LauncherLayoutMigration {
    let sourceVersion = 0
    let destinationVersion = 1

    func migrate(_ data: Data) throws -> Data {
        let legacy = try JSONDecoder().decode(LegacyLayoutDocument.self, from: data)
        let items = legacy.applicationPaths.map { path in
            LauncherLayoutItem.application(
                LauncherApplicationReference(identity: ApplicationIdentity.bundlePath(for: URL(fileURLWithPath: path))))
        }
        struct VersionOne: Encodable {
            let schemaVersion = 1
            let revision: UInt64
            let items: [LauncherLayoutItem]
        }
        return try JSONEncoder().encode(VersionOne(revision: legacy.revision, items: items))
    }
}
