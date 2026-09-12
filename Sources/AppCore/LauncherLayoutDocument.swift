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
    public static let currentSchemaVersion = 2

    public private(set) var schemaVersion: Int
    public private(set) var revision: UInt64
    /// Explicit page boundaries. A short (or empty interior) page is intentional;
    /// removing an item never pulls a replacement from the next page.
    public var pages: [[LauncherLayoutItem]]

    /// Compatibility projection for discovery/search and legacy whole-array edits.
    /// Page-aware mutations must edit `pages` or use `LauncherLayoutDraft`.
    public var items: [LauncherLayoutItem] {
        get { pages.flatMap { $0 } }
        set {
            guard pages.count > 1 else {
                pages = [newValue]
                return
            }
            var offset = 0
            pages = pages.enumerated().map { pageIndex, page in
                let end = pageIndex == pages.count - 1
                    ? newValue.count
                    : min(newValue.count, offset + page.count)
                defer { offset = end }
                return Array(newValue[offset..<end])
            }
        }
    }

    public init(revision: UInt64 = 0, items: [LauncherLayoutItem] = []) {
        self.init(revision: revision, pages: [items])
    }

    public init(revision: UInt64 = 0, pages: [[LauncherLayoutItem]]) {
        schemaVersion = Self.currentSchemaVersion
        self.revision = revision
        self.pages = pages.isEmpty ? [[]] : pages
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, items, pages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        switch version {
        case 1:
            // Capacity depends on the display. Retain the old flat order in one
            // page until the caller normalizes using its actual grid capacity.
            pages = [try container.decode([LauncherLayoutItem].self, forKey: .items)]
        case Self.currentSchemaVersion:
            pages = try container.decode([[LauncherLayoutItem]].self, forKey: .pages)
        default:
            throw LauncherLayoutValidationError.unsupportedSchemaVersion(version)
        }
        schemaVersion = Self.currentSchemaVersion
        revision = try container.decode(UInt64.self, forKey: .revision)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(pages, forKey: .pages)
    }

    /// Splits overflow forward without ever filling an earlier page's vacancy.
    /// A legacy flat page is consequently split once in its existing order.
    public func normalizedForPageCapacity(_ capacity: Int) -> Self {
        guard capacity > 0 else { return self }
        var result = self
        if result.pages.isEmpty { result.pages = [[]] }
        var pageIndex = 0
        while pageIndex < result.pages.count {
            if result.pages[pageIndex].count > capacity {
                let overflow = Array(result.pages[pageIndex].dropFirst(capacity))
                result.pages[pageIndex] = Array(result.pages[pageIndex].prefix(capacity))
                if pageIndex + 1 == result.pages.count {
                    result.pages.append(overflow)
                } else {
                    result.pages[pageIndex + 1].insert(contentsOf: overflow, at: 0)
                }
            }
            pageIndex += 1
        }
        while result.pages.count > 1, result.pages.last?.isEmpty == true {
            result.pages.removeLast()
        }
        return result
    }

    mutating func setRevision(_ revision: UInt64) {
        self.revision = revision
    }
}

public enum LauncherLayoutValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case layoutHasNoPages
    case duplicateApplication(ApplicationIdentity)
    case duplicateFolder(UUID)
    case folderHasFewerThanTwoApplications(UUID)
}

public enum LauncherLayoutValidator {
    public static func validate(_ document: LauncherLayoutDocument) throws {
        guard document.schemaVersion == LauncherLayoutDocument.currentSchemaVersion else {
            throw LauncherLayoutValidationError.unsupportedSchemaVersion(document.schemaVersion)
        }
        guard !document.pages.isEmpty else {
            throw LauncherLayoutValidationError.layoutHasNoPages
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
