import AppCore

/// Keeps first-page folder contents ahead of later work and deduplicates by identity.
struct IconWarmPlan {
    let firstPageFolderContents: [ApplicationRecord]
    let remaining: [ApplicationRecord]

    static func make(pages: [[ResolvedLaunchpadItem]], applications: [ApplicationRecord]) -> IconWarmPlan {
        var seen: Set<ApplicationIdentity> = []
        let firstPage = pages.first ?? []
        let folderChildren = firstPage.flatMap { item -> [ApplicationRecord] in
            guard case .folder(let folder) = item else { return [] }
            return folder.applications
        }
        let firstPageFolderContents = folderChildren.filter { seen.insert($0.id).inserted }
        let standalone = firstPage.compactMap { item -> ApplicationRecord? in
            guard case .application(let application) = item else { return nil }
            return application
        }
        let laterPages = pages.dropFirst().flatMap { page in
            page.flatMap { item -> [ApplicationRecord] in
                switch item {
                case .application(let application): [application]
                case .folder(let folder): folder.applications
                }
            }
        }
        let remaining = (standalone + laterPages + applications).filter { seen.insert($0.id).inserted }
        return IconWarmPlan(firstPageFolderContents: firstPageFolderContents, remaining: remaining)
    }
}
