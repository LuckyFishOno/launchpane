import Foundation

public actor AppCatalogActor {
    private let sources: [any AppDiscoverySource]
    private let excludedBundleIdentifiers: Set<String>
    private var cachedApplications: [ApplicationRecord] = []

    public init(
        sources: [any AppDiscoverySource] = [StandardApplicationDiscoverySource()],
        excludedBundleIdentifiers: Set<String> = []
    ) {
        self.sources = sources
        self.excludedBundleIdentifiers = Set(
            excludedBundleIdentifiers.map { $0.lowercased() }
        )
    }

    @discardableResult
    public func refresh() -> [ApplicationRecord] {
        refreshOutcome().applications
    }

    @discardableResult
    public func refreshOutcome() -> AppDiscoveryOutcome {
        var applicationsByIdentity: [ApplicationIdentity: ApplicationRecord] = [:]
        var completeness = LauncherCatalogCompleteness.complete

        for source in sources {
            do {
                let outcome = try source.discoverApplicationsWithCompleteness()
                if outcome.completeness == .partial {
                    completeness = .partial
                }
                for application in outcome.applications {
                    // LAUNCHPANE_SELF_CATALOG_EXCLUSION_V1
                    // Product-specific callers may remove applications from the
                    // canonical catalog by bundle identifier. Filtering here,
                    // before caching, keeps grid/search/reset behavior consistent.
                    if let bundleIdentifier = application.bundleIdentifier?.lowercased(),
                       excludedBundleIdentifiers.contains(bundleIdentifier) {
                        continue
                    }

                    guard applicationsByIdentity[application.id] == nil else { continue }
                    applicationsByIdentity[application.id] = application
                }
            } catch {
                completeness = .partial
            }
        }

        cachedApplications = applicationsByIdentity.values.sorted(by: Self.sortApplications)
        return AppDiscoveryOutcome(
            applications: cachedApplications,
            completeness: completeness
        )
    }

    public func applications(matching query: String = "") -> [ApplicationRecord] {
        cachedApplications
            .compactMap { application in
                application.searchScore(matching: query).map {
                    (application: application, score: $0)
                }
            }
            .sorted { left, right in
                if left.score != right.score {
                    return left.score > right.score
                }
                return Self.sortApplications(left.application, right.application)
            }
            .map(\.application)
    }

    private static func sortApplications(_ left: ApplicationRecord, _ right: ApplicationRecord) -> Bool {
        let nameComparison = left.displayName.localizedStandardCompare(right.displayName)
        if nameComparison == .orderedSame {
            return left.bundleURL.path < right.bundleURL.path
        }
        return nameComparison == .orderedAscending
    }
}
