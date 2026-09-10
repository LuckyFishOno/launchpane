import Foundation

public struct LauncherApplicationReference: Codable, Equatable, Hashable, Sendable {
    public var identity: ApplicationIdentity

    public init(identity: ApplicationIdentity) {
        self.identity = identity
    }

    public init(application: ApplicationRecord) {
        identity = application.id
    }
}

public struct LauncherFolder: Codable, Equatable, Sendable {
    public let id: UUID
    public var customTitle: String?
    public var applications: [LauncherApplicationReference]

    public init(
        id: UUID = UUID(),
        customTitle: String? = nil,
        applications: [LauncherApplicationReference]
    ) {
        self.id = id
        self.customTitle = customTitle
        self.applications = applications
    }
}

public enum LauncherLayoutItem: Equatable, Sendable {
    case application(LauncherApplicationReference)
    case folder(LauncherFolder)
}

extension LauncherLayoutItem: Codable {
    private enum Kind: String, Codable {
        case application
        case folder
    }

    private enum CodingKeys: String, CodingKey {
        case application
        case folder
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .application:
            self = try .application(container.decode(LauncherApplicationReference.self, forKey: .application))
        case .folder:
            self = try .folder(container.decode(LauncherFolder.self, forKey: .folder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .application(application):
            try container.encode(Kind.application, forKey: .kind)
            try container.encode(application, forKey: .application)
        case let .folder(folder):
            try container.encode(Kind.folder, forKey: .kind)
            try container.encode(folder, forKey: .folder)
        }
    }
}

public struct LauncherLayoutDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public private(set) var schemaVersion: Int
    public private(set) var revision: UInt64
    public var items: [LauncherLayoutItem]

    public init(revision: UInt64 = 0, items: [LauncherLayoutItem] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.revision = revision
        self.items = items
    }

    mutating func setRevision(_ revision: UInt64) {
        self.revision = revision
    }
}

public enum LauncherLayoutValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case duplicateApplication(ApplicationIdentity)
    case duplicateFolder(UUID)
    case folderHasFewerThanTwoApplications(UUID)
}

public enum LauncherLayoutValidator {
    public static func validate(_ document: LauncherLayoutDocument) throws {
        guard document.schemaVersion == LauncherLayoutDocument.currentSchemaVersion else {
            throw LauncherLayoutValidationError.unsupportedSchemaVersion(document.schemaVersion)
        }

        var applicationIdentities: Set<ApplicationIdentity> = []
        var folderIDs: Set<UUID> = []

        for item in document.items {
            switch item {
            case let .application(application):
                try insertUnique(application.identity, into: &applicationIdentities)
            case let .folder(folder):
                guard folderIDs.insert(folder.id).inserted else {
                    throw LauncherLayoutValidationError.duplicateFolder(folder.id)
                }
                guard folder.applications.count >= 2 else {
                    throw LauncherLayoutValidationError.folderHasFewerThanTwoApplications(folder.id)
                }
                for application in folder.applications {
                    try insertUnique(application.identity, into: &applicationIdentities)
                }
            }
        }
    }

    private static func insertUnique(
        _ identity: ApplicationIdentity,
        into identities: inout Set<ApplicationIdentity>
    ) throws {
        guard identities.insert(identity).inserted else {
            throw LauncherLayoutValidationError.duplicateApplication(identity)
        }
    }
}
