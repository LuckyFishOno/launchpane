// End-to-end reset check using the real menu callback and confirmation sheet.
// The layout path must point into /private/tmp so user data is never touched.
import AppCore
import AppKit

@MainActor
final class ResetLaunchpadCheckDelegate: NSObject, NSApplicationDelegate {
    private var controller: LaunchpadWindowController!
    private var failures = 0
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private var root: LaunchpadRootView {
        guard let root = controller.window?.contentView as? LaunchpadRootView else {
            fatalError("Expected the launcher window to contain LaunchpadRootView")
        }
        return root
    }
    private var layoutURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAUNCHPANE_LAYOUT_PATH"]!)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") \(message)")
        if !condition { failures += 1 }
    }

    private func pause(_ seconds: Double = 0.05) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @discardableResult
    private func until(_ message: String, timeout: Double = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { await pause() }
        let result = predicate()
        check(result, message)
        return result
    }

    private func storedDocument() throws -> LauncherLayoutDocument {
        try JSONDecoder().decode(LauncherLayoutDocument.self, from: Data(contentsOf: layoutURL))
    }

    private func alertButton(titled title: String) -> NSButton? {
        guard let sheet = controller.window?.attachedSheet, let content = sheet.contentView else { return nil }
        return descendants(content).compactMap { $0 as? NSButton }.first { $0.title == title }
    }

    private func run() async throws {
        let discovery = await AppCatalogActor().refreshOutcome()
        precondition(discovery.completeness == .complete && discovery.applications.count >= 3)
        let references = discovery.applications.map(LauncherApplicationReference.init(application:))
        let folder = LauncherFolder(applications: Array(references.prefix(2)))
        let fixture = LauncherLayoutDocument(revision: 400, pages: [
            [.application(references[2])],
            [.folder(folder)] + references.dropFirst(3).map(LauncherLayoutItem.application),
        ])
        try JSONEncoder().encode(fixture).write(to: layoutURL, options: .atomic)

        controller = LaunchpadWindowController()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        await until("fixture loaded") {
            Mirror(reflecting: self.root).children
                .first { $0.label == "isLoadingApplications" }?.value as? Bool == false
        }
        let search = descendants(root).compactMap { $0 as? LaunchpadSearchField }.first!
        let settings = descendants(search).compactMap { $0 as? NSButton }.first { $0.menu != nil }!

        settings.menu!.performActionForItem(at: 0)
        if await until("confirmation sheet opens", { alertButton(titled: "Cancel") != nil }) {
            alertButton(titled: "Cancel")?.performClick(nil)
            await until("cancel closes confirmation") {
                let isResetting = Mirror(reflecting: self.root).children
                    .first { $0.label == "isResettingLayout" }?.value as? Bool
                return controller.window?.attachedSheet == nil && isResetting == false
            }
            check(try storedDocument() == fixture, "cancel preserves the exact layout")
        }

        settings.menu!.performActionForItem(at: 0)
        if await until("reset confirmation opens", { alertButton(titled: "Reset Launchpad") != nil }) {
            alertButton(titled: "Reset Launchpad")?.performClick(nil)
            await until("reset transaction finishes") {
                guard controller.window?.attachedSheet == nil,
                      let document = try? self.storedDocument() else { return false }
                return document.revision == fixture.revision + 1
            }
            let document = try storedDocument()
            let expected = LauncherDefaultLayoutBuilder.makeDocument(
                applications: discovery.applications,
                revision: document.revision
            )
            check(document == expected, "reset restores the canonical default layout")
            check(document.items.filter {
                if case let .folder(folder) = $0 {
                    return folder.id != LauncherDefaultLayoutBuilder.utilitiesFolderID
                }
                return false
            }.isEmpty, "reset removes custom folders and retains only default Utilities")
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        Task { @MainActor in
            do { try await run() } catch { check(false, "unexpected error: \(error)") }
            controller?.restoreSystemPresentationForTermination()
            controller?.close()
            previousApp?.activate(options: [])
            print("RESET LAUNCHPAD: \(failures) failures")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

@main
struct ResetLaunchpadCheck {
    @MainActor static func main() {
        precondition(ProcessInfo.processInfo.environment["LAUNCHPANE_LAYOUT_PATH"]?.hasPrefix("/private/tmp/") == true)
        let app = NSApplication.shared
        let delegate = ResetLaunchpadCheckDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
