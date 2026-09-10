import Foundation

public struct AppDiscoveryOutcome: Equatable, Sendable {
    public let applications: [ApplicationRecord]
    public let completeness: LauncherCatalogCompleteness

    public init(
        applications: [ApplicationRecord],
        completeness: LauncherCatalogCompleteness
    ) {
        self.applications = applications
        self.completeness = completeness
    }
}

public protocol AppDiscoverySource: Sendable {
    func discoverApplications() throws -> [ApplicationRecord]
    func discoverApplicationsWithCompleteness() throws -> AppDiscoveryOutcome
}

public extension AppDiscoverySource {
    func discoverApplicationsWithCompleteness() throws -> AppDiscoveryOutcome {
        try AppDiscoveryOutcome(
            applications: discoverApplications(),
            completeness: .complete
        )
    }
}

public struct StandardApplicationDiscoverySource: AppDiscoverySource, Sendable {
    public let roots: [URL]
    private let metadataResolver: AppMetadataResolver
    private let directoryScanner: any ApplicationRootScanning
    private let optionalRoots: Set<URL>

    public init(
        roots: [URL] = Self.defaultRoots,
        optionalRoots: Set<URL>? = nil,
        metadataResolver: AppMetadataResolver = AppMetadataResolver()
    ) {
        self.roots = roots
        self.metadataResolver = metadataResolver
        directoryScanner = FileManagerApplicationRootScanner()
        self.optionalRoots = Self.standardizedRoots(
            optionalRoots ?? [Self.defaultUserApplicationsRoot]
        )
    }

    init(
        roots: [URL],
        optionalRoots: Set<URL> = [],
        metadataResolver: AppMetadataResolver = AppMetadataResolver(),
        directoryScanner: any ApplicationRootScanning
    ) {
        self.roots = roots
        self.metadataResolver = metadataResolver
        self.directoryScanner = directoryScanner
        self.optionalRoots = Self.standardizedRoots(optionalRoots)
    }

    public func discoverApplications() throws -> [ApplicationRecord] {
        try discoverApplicationsWithCompleteness().applications
    }

    public func discoverApplicationsWithCompleteness() throws -> AppDiscoveryOutcome {
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        var applications: [ApplicationRecord] = []
        var completeness = LauncherCatalogCompleteness.complete

        for root in roots {
            let scan = directoryScanner.scanApplicationURLs(
                in: root,
                resourceKeys: resourceKeys
            )
            switch scan {
            case .missing:
                if !optionalRoots.contains(root.standardizedFileURL) {
                    completeness = .partial
                }
            case let .complete(urls):
                for url in urls {
                    guard let application = metadataResolver.resolve(bundleURL: url) else { continue }
                    applications.append(application)
                }
            case let .partial(urls):
                completeness = .partial
                for url in urls {
                    guard let application = metadataResolver.resolve(bundleURL: url) else { continue }
                    applications.append(application)
                }
            }
        }
        return AppDiscoveryOutcome(
            applications: applications,
            completeness: completeness
        )
    }

    public static var defaultRoots: [URL] {
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        ]
        roots.append(defaultUserApplicationsRoot)
        return roots
    }

    private static var defaultUserApplicationsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    }

    private static func standardizedRoots(_ roots: Set<URL>) -> Set<URL> {
        Set(roots.map(\.standardizedFileURL))
    }
}

enum ApplicationRootScanOutcome: Sendable {
    case missing
    case complete([URL])
    case partial([URL])
}

protocol ApplicationRootScanning: Sendable {
    func scanApplicationURLs(
        in root: URL,
        resourceKeys: [URLResourceKey]
    ) -> ApplicationRootScanOutcome
}

private struct FileManagerApplicationRootScanner: ApplicationRootScanning {
    func scanApplicationURLs(
        in root: URL,
        resourceKeys: [URLResourceKey]
    ) -> ApplicationRootScanOutcome {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return .missing }

        let failureTracker = EnumerationFailureTracker()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                failureTracker.markFailure()
                return true
            }
        ) else {
            return .partial([])
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            urls.append(url)
        }
        return failureTracker.didFail ? .partial(urls) : .complete(urls)
    }
}

private final class EnumerationFailureTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var failure = false

    var didFail: Bool {
        lock.withLock { failure }
    }

    func markFailure() {
        lock.withLock {
            failure = true
        }
    }
}
