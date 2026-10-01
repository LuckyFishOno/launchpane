// Drives real AppTileButton events against an isolated persisted catalog.
// Reflection only observes private runtime state; no alternate drag path or
// production test hook is used. Requires a logged-in macOS graphical session.
import AppCore
import AppKit
import LayoutCore
import QuartzCore

@MainActor final class FolderMergeCheckDelegate: NSObject, NSApplicationDelegate {
    var controller: LaunchpadWindowController!
    let previousApp = NSWorkspace.shared.frontmostApplication
    var failures = 0
    var fixture = LauncherLayoutDocument()
    var references: [LauncherApplicationReference] = []
    var sourceID: ApplicationIdentity!
    var targetIndex = 0

    var root: LaunchpadRootView {
        guard let root = controller.window?.contentView as? LaunchpadRootView else {
            fatalError("Expected the launcher window to contain LaunchpadRootView")
        }
        return root
    }
    var layoutURL: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAUNCHPANE_LAYOUT_PATH"]!) }
    func value<T>(_ object: Any, _ key: String, as: T.Type = T.self) -> T? {
        guard let raw = Mirror(reflecting: object).children.first(where: { $0.label == key })?.value else { return nil }
        let mirror = Mirror(reflecting: raw)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return nil }
            return child.value as? T
        }
        return raw as? T
    }
    var session: Any? { value(root, "dragSession", as: Any.self) }
    var intent: LauncherDragIntentState? { session.flatMap { value($0, "intentState") } }
    var metrics: GridMetrics { value(root, "currentMetrics")! }
    var targetID: ApplicationIdentity { references[targetIndex].identity }

    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") \(message)")
        if !condition { failures += 1 }
    }
    func pause(_ seconds: Double = 0.05) async { try? await Task.sleep(for: .seconds(seconds)) }
    @discardableResult func until(_ message: String, timeout: Double = 6, _ predicate: () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while !predicate(), CACurrentMediaTime() < deadline { await pause(0.015) }
        let result = predicate()
        check(result, message)
        return result
    }
    func persisted() throws -> LauncherLayoutDocument {
        try JSONDecoder().decode(LauncherLayoutDocument.self, from: Data(contentsOf: layoutURL))
    }
    func openFixture(_ replacement: LauncherLayoutDocument? = nil) async throws {
        if let replacement { fixture = replacement }
        if controller != nil {
            controller.restoreSystemPresentationForTermination()
            controller.close()
            await pause(0.15)
        }
        try JSONEncoder().encode(fixture).write(to: layoutURL, options: .atomic)
        controller = LaunchpadWindowController()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        await until("fixture catalog loaded") { value(root, "isLoadingApplications") == false }
        root.layoutSubtreeIfNeeded()
        await pause(0.3)
    }
    func settled() async {
        await until("drag and persistence settled") {
            session == nil && value(root, "isCommittingLayout") == false
                && value(root, "isFinishingDragVisuals") == false
        }
        root.layoutSubtreeIfNeeded()
        await pause(0.1)
    }
    func entry(_ identifier: LauncherLayoutItemIdentifier) -> Any? {
        let surface: Any? =
            session.flatMap { value($0, "previewSurface", as: Any.self) } ?? value(root, "activeSurface", as: Any.self)
        guard let surface, let entries: Any = value(surface, "entries", as: Any.self) else { return nil }
        return Mirror(reflecting: entries).children.map(\.value).first {
            value($0, "item", as: ResolvedLaunchpadItem.self)?.id == identifier
        }
    }
    func frames(_ identifier: LauncherLayoutItemIdentifier) -> GridItemFrames? {
        entry(identifier).flatMap { value($0, "frames") }
    }
    func tileLayer(_ identifier: LauncherLayoutItemIdentifier) -> CALayer? {
        guard let entry = entry(identifier), let presentation: Any = value(entry, "presentation", as: Any.self),
            let payload = Mirror(reflecting: presentation).children.first?.value
        else { return nil }
        if let application = payload as? AppTilePresentation { return application.tileLayer }
        if let folder = payload as? FolderTilePresentation { return folder.tileLayer }
        return nil
    }
    func selectionLayer(_ identifier: LauncherLayoutItemIdentifier) -> CALayer? {
        guard let entry = entry(identifier), let presentation: Any = value(entry, "presentation", as: Any.self),
            let payload = Mirror(reflecting: presentation).children.first?.value
        else { return nil }
        if let application = payload as? AppTilePresentation { return application.selectionLayer }
        if let folder = payload as? FolderTilePresentation { return folder.selectionLayer }
        return nil
    }
    func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    func unchanged(_ identifier: LauncherLayoutItemIdentifier, from baseline: GridItemFrames) -> Bool {
        guard frames(identifier) == baseline, let layer = tileLayer(identifier) else { return false }
        let visible = layer.presentation()?.position ?? layer.position
        return hypot(visible.x - baseline.cell.midX, visible.y - baseline.cell.midY) < 1
    }
    func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: root.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window!.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func press(offset: CGVector = .zero) -> AppTileButton {
        let button = descendants(root).compactMap { $0 as? AppTileButton }.first { $0.application.id == sourceID }!
        let icon = frames(.application(sourceID))!.icon
        button.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: icon.midX + offset.dx, y: icon.midY + offset.dy)))
        return button
    }
    func drag(_ button: AppTileButton, to point: CGPoint) {
        button.mouseDragged(with: event(.leftMouseDragged, at: point))
    }
    func release(_ button: AppTileButton, at point: CGPoint) async {
        button.mouseUp(with: event(.leftMouseUp, at: point))
        await settled()
    }
    func cancel(_ button: AppTileButton) async throws {
        let oldSession = session
        button.cancelOperation(nil)
        await settled()
        await pause(0.5)
        check(!button.isTrackingPointer && session == nil, "Escape releases the real pointer owner")
        check(
            oldSession.flatMap { value($0, "intentTask", as: Any.self) } == nil,
            "Escape removes the delayed intent task")
        check(
            oldSession.flatMap { value($0, "folderSpringOpenTask", as: Any.self) } == nil,
            "Escape removes the delayed spring-open task")
        check(try persisted() == fixture, "Escape leaves the exact persisted layout unchanged")
    }
    func allIDs(_ document: LauncherLayoutDocument) -> [ApplicationIdentity] {
        document.items.flatMap { item in
            switch item {
            case .application(let reference): [reference.identity]
            case .folder(let folder): folder.applications.map(\.identity)
            }
        }
    }
    func folders(_ document: LauncherLayoutDocument) -> [LauncherFolder] {
        document.items.compactMap { if case .folder(let folder) = $0 { folder } else { nil } }
    }
    func verifyOneCommit(_ document: LauncherLayoutDocument) {
        check(document.revision == fixture.revision + 1, "drop persists exactly one revision")
        let actual = allIDs(document)
        check(
            actual.count == allIDs(fixture).count && Set(actual) == Set(allIDs(fixture)),
            "every original application occurs exactly once")
    }

    struct ApproachDirection {
        let name: String
        let horizontal: Int
        let vertical: Int
    }

    func run() async throws {
        let discovery = await AppCatalogActor(excludedBundleIdentifiers: [
            "org.launchpane.LaunchPane", "org.launchpane.LaunchPaneAgent",
        ]).refreshOutcome()
        precondition(discovery.completeness == .complete, "Needs a complete installed-app catalog")
        references = discovery.applications.map(LauncherApplicationReference.init(application:))
        fixture = LauncherLayoutDocument(revision: 900, items: references.map(LauncherLayoutItem.application))
        try await openFixture()
        precondition(
            metrics.columns >= 5 && metrics.rows >= 3 && references.count >= metrics.columns * 3,
            "Needs an interior target and at least three complete app rows")
        targetIndex = metrics.columns + metrics.columns / 2
        try await checkEightApproaches()
        try await checkDirectOverlapAndCommit()
        try await checkSpringOpenAfterTwoSeconds()
        try await checkLeavingAndRestart()
        try await checkReorderAndOffset()
        try await checkExistingFolder()
        try await checkFailedCommitRollback()
    }

    func applicationDidFinishLaunching(_: Notification) {
        Task { @MainActor in
            do { try await run() } catch { check(false, "unexpected error: \(error)") }
            controller?.restoreSystemPresentationForTermination()
            controller?.close()
            previousApp?.activate(options: [])
            print("FOLDER MERGE: \(failures) failures")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

@main struct FolderMergeCheck {
    @MainActor static func main() {
        precondition(
            ProcessInfo.processInfo.environment["LAUNCHPANE_LAYOUT_PATH"]?.hasPrefix("/private/tmp/") == true,
            "Use an isolated layout file under /private/tmp")
        let app = NSApplication.shared
        let delegate = FolderMergeCheckDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
