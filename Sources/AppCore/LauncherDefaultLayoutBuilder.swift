import Foundation

/// Creates the layout used only when LaunchPane has no persisted arrangement.
public enum LauncherDefaultLayoutBuilder {
    public static let utilitiesFolderID = UUID(
        uuid: (0x4F, 0x50, 0x45, 0x4E, 0x4C, 0x41, 0x55, 0x4E,
               0x43, 0x48, 0x50, 0x41, 0x44, 0x55, 0x54, 0x49)
    )

    private static let systemUtilitiesDirectory = URL(
        fileURLWithPath: "/System/Applications/Utilities",
        isDirectory: true
    ).standardizedFileURL

    public static func makeDocument(
        applications: [ApplicationRecord],
        revision: UInt64 = 0
    ) -> LauncherLayoutDocument {
        var seen: Set<ApplicationIdentity> = []
        let uniqueApplications = applications.filter { seen.insert($0.id).inserted }
        let utilities = uniqueApplications.filter(isSystemUtility)

        guard utilities.count >= 2 else {
            return LauncherLayoutDocument(
                revision: revision,
                items: uniqueApplications.map(applicationItem)
            )
        }

        let utilityIdentities = Set(utilities.map(\.id))
        let folder = LauncherLayoutItem.folder(
            LauncherFolder(
                id: utilitiesFolderID,
                customTitle: "Utilities",
                applications: utilities.map(LauncherApplicationReference.init(application:))
            )
        )
        // Utilities is the fixed first item on page one. Remaining applications
        // retain discovery order after the utility children are removed.
        let items = [folder] + uniqueApplications.compactMap { application in
            utilityIdentities.contains(application.id) ? nil : applicationItem(application)
        }

        return LauncherLayoutDocument(revision: revision, items: items)
    }

    public static func isSystemUtility(_ application: ApplicationRecord) -> Bool {
        application.bundleURL.standardizedFileURL.deletingLastPathComponent().path
            == systemUtilitiesDirectory.path
    }

    private static func applicationItem(_ application: ApplicationRecord) -> LauncherLayoutItem {
        .application(LauncherApplicationReference(application: application))
    }
}
