import AppCore
import Foundation

struct ResolvedLaunchpadFolder: Sendable {
    let id: UUID
    let title: String
    let applications: [ApplicationRecord]
}

enum ResolvedLaunchpadItem: Sendable {
    case application(ApplicationRecord)
    case folder(ResolvedLaunchpadFolder)

    var id: LauncherLayoutItemIdentifier {
        switch self {
        case let .application(application):
            .application(application.id)
        case let .folder(folder):
            .folder(folder.id)
        }
    }

    var displayName: String {
        switch self {
        case let .application(application):
            application.displayName
        case let .folder(folder):
            folder.title
        }
    }

    var rootApplicationIdentity: ApplicationIdentity? {
        guard case let .application(application) = self else { return nil }
        return application.id
    }

    var folderID: UUID? {
        guard case let .folder(folder) = self else { return nil }
        return folder.id
    }
}

/// Persisted pages own their gaps; flat indices exist only for tile selection.
struct ResolvedLaunchpadPages: Sendable {
    let pages: [[ResolvedLaunchpadItem]]
    let items: [ResolvedLaunchpadItem]
    let ranges: [Range<Int>]

    var pageCount: Int { pages.count }

    init(pages: [[ResolvedLaunchpadItem]]) {
        self.pages = pages.isEmpty ? [[]] : pages
        items = self.pages.flatMap { $0 }
        var offset = 0
        ranges = self.pages.map { page in
            let range = offset ..< offset + page.count
            offset = range.upperBound
            return range
        }
    }

    func range(forPage pageIndex: Int) -> Range<Int> {
        guard ranges.indices.contains(pageIndex) else {
            let boundary = pageIndex < 0 ? 0 : items.count
            return boundary ..< boundary
        }
        return ranges[pageIndex]
    }

    func pageIndex(containing flatIndex: Int) -> Int? {
        guard items.indices.contains(flatIndex) else { return nil }
        return ranges.firstIndex { $0.contains(flatIndex) }
    }

    func localIndex(forFlatIndex flatIndex: Int) -> Int? {
        guard let pageIndex = pageIndex(containing: flatIndex) else { return nil }
        return flatIndex - ranges[pageIndex].lowerBound
    }
}

/// Converts a visible final slot into the persisted index after source removal.
/// An incomplete app catalog may omit references that still own layout slots.
enum ResolvedLaunchpadInsertionIndex {
    static func resolve(
        visibleSlot: Int,
        pageIdentifiers: [LauncherLayoutItemIdentifier],
        visibleIdentifiers: [LauncherLayoutItemIdentifier],
        sourceIdentifier: LauncherLayoutItemIdentifier
    ) -> Int? {
        guard visibleSlot >= 0 else { return nil }
        let remaining = pageIdentifiers.filter { $0 != sourceIdentifier }
        let visible = visibleIdentifiers.filter { $0 != sourceIdentifier }
        let visibleSet = Set(visible)
        guard remaining.filter({ visibleSet.contains($0) }) == visible else { return nil }
        let slot = min(visibleSlot, visible.count)

        // Releasing on the original visible slot is a genuine no-op, including
        // when unresolved references occur immediately before/after the source.
        if visibleIdentifiers.firstIndex(of: sourceIdentifier) == slot,
           let originalIndex = pageIdentifiers.firstIndex(of: sourceIdentifier) {
            return originalIndex
        }
        if slot < visible.count {
            return remaining.firstIndex(of: visible[slot])
        }
        // Append after the final visible app, not after an unresolved tail.
        if let lastVisible = visible.last,
           let lastIndex = remaining.firstIndex(of: lastVisible) {
            return lastIndex + 1
        }
        return 0
    }
}

enum ResolvedLaunchpadItemFactory {
    static func makePages(
        document: LauncherLayoutDocument,
        applications: [ApplicationRecord],
        query: String,
        pageCapacity: Int
    ) -> ResolvedLaunchpadPages {
        let capacity = max(1, pageCapacity)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedQuery.isEmpty {
            let matches = makeItems(
                document: document,
                applications: applications,
                query: normalizedQuery
            )
            return ResolvedLaunchpadPages(pages: stride(
                from: 0,
                to: matches.count,
                by: capacity
            ).map { start in
                Array(matches[start ..< min(start + capacity, matches.count)])
            })
        }

        let applicationsByIdentity = applicationLookup(applications)
        let normalizedDocument = document.normalizedForPageCapacity(capacity)
        return ResolvedLaunchpadPages(pages: normalizedDocument.pages.map { page in
            resolveItems(page, applicationsByIdentity: applicationsByIdentity)
        })
    }

    static func makeItems(
        document: LauncherLayoutDocument,
        applications: [ApplicationRecord],
        query: String
    ) -> [ResolvedLaunchpadItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedQuery.isEmpty {
            return applications
                .compactMap { application in
                    application.searchScore(matching: normalizedQuery).map {
                        (application: application, score: $0)
                    }
                }
                .sorted { left, right in
                    if left.score != right.score {
                        return left.score > right.score
                    }
                    let nameComparison = left.application.displayName.localizedStandardCompare(
                        right.application.displayName
                    )
                    if nameComparison != .orderedSame {
                        return nameComparison == .orderedAscending
                    }
                    return left.application.bundleURL.path < right.application.bundleURL.path
                }
                .map(\.application)
                .map(ResolvedLaunchpadItem.application)
        }

        return resolveItems(
            document.items,
            applicationsByIdentity: applicationLookup(applications)
        )
    }

    private static func applicationLookup(
        _ applications: [ApplicationRecord]
    ) -> [ApplicationIdentity: ApplicationRecord] {
        Dictionary(
            applications.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func resolveItems(
        _ items: [LauncherLayoutItem],
        applicationsByIdentity: [ApplicationIdentity: ApplicationRecord]
    ) -> [ResolvedLaunchpadItem] {
        items.compactMap { item in
            switch item {
            case let .application(reference):
                return applicationsByIdentity[reference.identity].map(ResolvedLaunchpadItem.application)
            case let .folder(folder):
                let applications = folder.applications.compactMap {
                    applicationsByIdentity[$0.identity]
                }
                guard applications.count >= 2 else { return nil }
                return .folder(ResolvedLaunchpadFolder(
                    id: folder.id,
                    title: resolvedFolderTitle(folder.customTitle),
                    applications: applications
                ))
            }
        }
    }

    private static func resolvedFolderTitle(_ customTitle: String?) -> String {
        let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty || title.caseInsensitiveCompare("untitled") == .orderedSame {
            return "Untitled"
        }
        return title
    }
}
