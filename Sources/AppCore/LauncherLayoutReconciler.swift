import Foundation

public enum LauncherCatalogCompleteness: Equatable, Sendable {
    /// Every configured discovery source completed, so missing applications may be pruned.
    case complete
    /// At least one source failed or was unavailable. Missing references must be retained.
    case partial
}

public struct LauncherIdentityCanonicalization: Equatable, Sendable {
    public let previous: ApplicationIdentity
    public let current: ApplicationIdentity

    public init(previous: ApplicationIdentity, current: ApplicationIdentity) {
        self.previous = previous
        self.current = current
    }
}

public struct LauncherLayoutReconciliationReport: Equatable, Sendable {
    public var addedApplications: [ApplicationIdentity]
    public var removedApplications: [ApplicationIdentity]
    public var deduplicatedApplications: [ApplicationIdentity]
    public var canonicalizedApplications: [LauncherIdentityCanonicalization]
    public var removedFolders: [UUID]
    public var dissolvedFolders: [UUID]

    public init(
        addedApplications: [ApplicationIdentity] = [],
        removedApplications: [ApplicationIdentity] = [],
        deduplicatedApplications: [ApplicationIdentity] = [],
        canonicalizedApplications: [LauncherIdentityCanonicalization] = [],
        removedFolders: [UUID] = [],
        dissolvedFolders: [UUID] = []
    ) {
        self.addedApplications = addedApplications
        self.removedApplications = removedApplications
        self.deduplicatedApplications = deduplicatedApplications
        self.canonicalizedApplications = canonicalizedApplications
        self.removedFolders = removedFolders
        self.dissolvedFolders = dissolvedFolders
    }
}

public struct LauncherLayoutReconciliationResult: Equatable, Sendable {
    public let document: LauncherLayoutDocument
    public let report: LauncherLayoutReconciliationReport

    public var changed: Bool {
        !report.addedApplications.isEmpty
            || !report.removedApplications.isEmpty
            || !report.deduplicatedApplications.isEmpty
            || !report.canonicalizedApplications.isEmpty
            || !report.removedFolders.isEmpty
            || !report.dissolvedFolders.isEmpty
    }

    public init(
        document: LauncherLayoutDocument,
        report: LauncherLayoutReconciliationReport
    ) {
        self.document = document
        self.report = report
    }
}

public enum LauncherLayoutReconciler {
    public static func reconcile(
        _ document: LauncherLayoutDocument,
        with applications: [ApplicationRecord],
        completeness: LauncherCatalogCompleteness = .complete
    ) -> LauncherLayoutReconciliationResult {
        let catalog = uniqueCatalog(applications)
        var accumulator = ReconciliationAccumulator(
            catalog: catalog,
            completeness: completeness
        )
        let reconciledItems = accumulator.reconcile(document.items)

        let reconciledDocument = LauncherLayoutDocument(
            revision: document.revision,
            items: reconciledItems
        )
        return LauncherLayoutReconciliationResult(
            document: reconciledDocument,
            report: accumulator.report
        )
    }

    private static func uniqueCatalog(_ applications: [ApplicationRecord]) -> [ApplicationRecord] {
        var seen: Set<ApplicationIdentity> = []
        return applications.filter { seen.insert($0.id).inserted }
    }
}

private struct ReconciliationAccumulator {
    let catalog: [ApplicationRecord]
    let completeness: LauncherCatalogCompleteness
    let catalogIdentities: Set<ApplicationIdentity>
    let pathAliases: [ApplicationIdentity: ApplicationIdentity]

    var report = LauncherLayoutReconciliationReport()
    var claimedApplications: Set<ApplicationIdentity> = []
    var claimedFolders: Set<UUID> = []

    init(catalog: [ApplicationRecord], completeness: LauncherCatalogCompleteness) {
        self.catalog = catalog
        self.completeness = completeness
        catalogIdentities = Set(catalog.map(\.id))
        pathAliases = Dictionary(
            catalog.map { (ApplicationIdentity.bundlePath(for: $0.bundleURL), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    mutating func reconcile(_ items: [LauncherLayoutItem]) -> [LauncherLayoutItem] {
        var result = items.flatMap { reconcile($0) }
        for application in catalog where claimedApplications.insert(application.id).inserted {
            result.append(.application(LauncherApplicationReference(application: application)))
            report.addedApplications.append(application.id)
        }
        return result
    }

    private mutating func reconcile(_ item: LauncherLayoutItem) -> [LauncherLayoutItem] {
        switch item {
        case let .application(application):
            return reconcile(application).map { [.application($0)] } ?? []
        case let .folder(folder):
            let applications = folder.applications.compactMap { reconcile($0) }
            let hasUniqueID = claimedFolders.insert(folder.id).inserted
            if applications.isEmpty {
                report.removedFolders.append(folder.id)
                return []
            }
            if applications.count == 1 || !hasUniqueID {
                report.dissolvedFolders.append(folder.id)
                return applications.map(LauncherLayoutItem.application)
            }
            return [.folder(LauncherFolder(
                id: folder.id,
                customTitle: folder.customTitle,
                applications: applications
            ))]
        }
    }

    private mutating func reconcile(
        _ reference: LauncherApplicationReference
    ) -> LauncherApplicationReference? {
        let canonicalIdentity: ApplicationIdentity? = if catalogIdentities.contains(reference.identity) {
            reference.identity
        } else {
            pathAliases[reference.identity]
        }

        if let canonicalIdentity {
            return claimCanonical(canonicalIdentity, replacing: reference.identity)
        }
        guard completeness == .partial else {
            report.removedApplications.append(reference.identity)
            return nil
        }
        return claim(reference)
    }

    private mutating func claimCanonical(
        _ identity: ApplicationIdentity,
        replacing previousIdentity: ApplicationIdentity
    ) -> LauncherApplicationReference? {
        guard claimedApplications.insert(identity).inserted else {
            report.deduplicatedApplications.append(previousIdentity)
            return nil
        }
        if identity != previousIdentity {
            report.canonicalizedApplications.append(LauncherIdentityCanonicalization(
                previous: previousIdentity,
                current: identity
            ))
        }
        return LauncherApplicationReference(identity: identity)
    }

    private mutating func claim(
        _ reference: LauncherApplicationReference
    ) -> LauncherApplicationReference? {
        guard claimedApplications.insert(reference.identity).inserted else {
            report.deduplicatedApplications.append(reference.identity)
            return nil
        }
        return reference
    }
}
