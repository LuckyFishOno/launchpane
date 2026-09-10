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

enum ResolvedLaunchpadItemFactory {
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

        let applicationsByIdentity = Dictionary(
            applications.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return document.items.compactMap { item in
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
        return title.isEmpty ? "Folder" : title
    }
}
