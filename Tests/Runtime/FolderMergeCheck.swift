// Drives real AppTileButton events against an isolated persisted catalog.
// Reflection only observes private runtime state; no alternate drag path or
// production test hook is used. Requires a logged-in macOS graphical session.
import AppCore
import AppKit
import LayoutCore
import QuartzCore

@MainActor
final class FolderMergeCheckDelegate: NSObject, NSApplicationDelegate {
    private var controller: LaunchpadWindowController!
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private var failures = 0
    private var fixture = LauncherLayoutDocument()
    private var references: [LauncherApplicationReference] = []
    private var sourceID: ApplicationIdentity!
    private var targetIndex = 0

    private var root: LaunchpadRootView { controller.window!.contentView as! LaunchpadRootView }
    private var layoutURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPENLAUNCHPAD_LAYOUT_PATH"]!)
    }
    private func value<T>(_ object: Any, _ key: String, as: T.Type = T.self) -> T? {
        guard let raw = Mirror(reflecting: object).children.first(where: { $0.label == key })?.value else {
            return nil
        }
        let mirror = Mirror(reflecting: raw)
        if mirror.displayStyle == .optional {
            return mirror.children.first?.value as? T
        }
        return raw as? T
    }
    private var session: Any? { value(root, "dragSession", as: Any.self) }
    private var intent: LauncherDragIntentState? {
        session.flatMap { value($0, "intentState") }
    }
    private var metrics: GridMetrics { value(root, "currentMetrics")! }
    private var targetID: ApplicationIdentity { references[targetIndex].identity }

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
    private func until(_ message: String, timeout: Double = 6, _ predicate: () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while !predicate(), CACurrentMediaTime() < deadline { await pause(0.015) }
        let result = predicate()
        check(result, message)
        return result
    }
    private func persisted() throws -> LauncherLayoutDocument {
        try JSONDecoder().decode(LauncherLayoutDocument.self, from: Data(contentsOf: layoutURL))
    }
    private func openFixture(_ replacement: LauncherLayoutDocument? = nil) async throws {
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
    private func settled() async {
        await until("drag and persistence settled") {
            session == nil && value(root, "isCommittingLayout") == false
                && value(root, "isFinishingDragVisuals") == false
        }
        root.layoutSubtreeIfNeeded()
        await pause(0.1)
    }
    private func entry(_ identifier: LauncherLayoutItemIdentifier) -> Any? {
        let surface: Any? = session.flatMap { value($0, "previewSurface", as: Any.self) }
            ?? value(root, "activeSurface", as: Any.self)
        guard let surface, let entries: Any = value(surface, "entries", as: Any.self) else { return nil }
        return Mirror(reflecting: entries).children.map(\.value).first {
            value($0, "item", as: ResolvedLaunchpadItem.self)?.id == identifier
        }
    }
    private func frames(_ identifier: LauncherLayoutItemIdentifier) -> GridItemFrames? {
        entry(identifier).flatMap { value($0, "frames") }
    }
    private func tileLayer(_ identifier: LauncherLayoutItemIdentifier) -> CALayer? {
        guard let entry = entry(identifier),
              let presentation: Any = value(entry, "presentation", as: Any.self),
              let payload = Mirror(reflecting: presentation).children.first?.value else { return nil }
        if let application = payload as? AppTilePresentation { return application.tileLayer }
        if let folder = payload as? FolderTilePresentation { return folder.tileLayer }
        return nil
    }
    private func selectionLayer(_ identifier: LauncherLayoutItemIdentifier) -> CALayer? {
        guard let entry = entry(identifier),
              let presentation: Any = value(entry, "presentation", as: Any.self),
              let payload = Mirror(reflecting: presentation).children.first?.value else { return nil }
        if let application = payload as? AppTilePresentation { return application.selectionLayer }
        if let folder = payload as? FolderTilePresentation { return folder.selectionLayer }
        return nil
    }
    private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    private func unchanged(_ identifier: LauncherLayoutItemIdentifier, from baseline: GridItemFrames) -> Bool {
        guard frames(identifier) == baseline, let layer = tileLayer(identifier) else { return false }
        let visible = layer.presentation()?.position ?? layer.position
        return hypot(visible.x - baseline.cell.midX, visible.y - baseline.cell.midY) < 1
    }
    private func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: root.convert(point, to: nil),
                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: controller.window!.windowNumber, context: nil,
                          eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    private func press(offset: CGVector = .zero) -> AppTileButton {
        let button = descendants(root).compactMap { $0 as? AppTileButton }
            .first { $0.application.id == sourceID }!
        let icon = frames(.application(sourceID))!.icon
        button.mouseDown(with: event(.leftMouseDown, at:
            CGPoint(x: icon.midX + offset.dx, y: icon.midY + offset.dy)))
        return button
    }
    private func drag(_ button: AppTileButton, to point: CGPoint) {
        button.mouseDragged(with: event(.leftMouseDragged, at: point))
    }
    private func release(_ button: AppTileButton, at point: CGPoint) async {
        button.mouseUp(with: event(.leftMouseUp, at: point))
        await settled()
    }
    private func cancel(_ button: AppTileButton) async throws {
        let oldSession = session
        button.cancelOperation(nil)
        await settled()
        await pause(0.5)
        check(!button.isTrackingPointer && session == nil, "Escape releases the real pointer owner")
        check(oldSession.flatMap { value($0, "intentTask", as: Any.self) } == nil,
              "Escape removes the delayed intent task")
        check(oldSession.flatMap { value($0, "folderSpringOpenTask", as: Any.self) } == nil,
              "Escape removes the delayed spring-open task")
        check(try persisted() == fixture, "Escape leaves the exact persisted layout unchanged")
    }
    private func allIDs(_ document: LauncherLayoutDocument) -> [ApplicationIdentity] {
        document.items.flatMap { item in
            switch item {
            case let .application(reference): [reference.identity]
            case let .folder(folder): folder.applications.map(\.identity)
            }
        }
    }
    private func folders(_ document: LauncherLayoutDocument) -> [LauncherFolder] {
        document.items.compactMap { if case let .folder(folder) = $0 { folder } else { nil } }
    }
    private func verifyOneCommit(_ document: LauncherLayoutDocument) {
        check(document.revision == fixture.revision + 1, "drop persists exactly one revision")
        let actual = allIDs(document)
        check(actual.count == allIDs(fixture).count && Set(actual) == Set(allIDs(fixture)),
              "every original application occurs exactly once")
    }

    private func checkEightApproaches() async throws {
        // Each source is the genuine adjacent side/corner icon. Beginning just
        // outside the target cell must not push it away before entering its icon.
        let directions: [(String, Int, Int)] = [
            ("left", -1, 0), ("right", 1, 0), ("above", 0, 1), ("below", 0, -1),
            ("upper left", -1, 1), ("upper right", 1, 1),
            ("lower left", -1, -1), ("lower right", 1, -1),
        ]
        for (name, x, y) in directions {
            try await openFixture()
            let sourceColumnDelta = metrics.isRightToLeft ? -x : x
            sourceID = references[targetIndex + sourceColumnDelta - y * metrics.columns].identity
            let identifier = LauncherLayoutItemIdentifier.application(targetID)
            let baseline = frames(identifier)!
            let destination = center(baseline.icon)
            let start = CGPoint(
                x: x < 0 ? baseline.cell.minX - 6 : x > 0 ? baseline.cell.maxX + 6 : destination.x,
                y: y < 0 ? baseline.cell.minY - 6 : y > 0 ? baseline.cell.maxY + 6 : destination.y
            )
            let button = press()
            drag(button, to: start)
            var targetStayedStill = unchanged(identifier, from: baseline)
            let steps = max(1, Int(ceil(hypot(start.x - destination.x, start.y - destination.y) / 5)))
            for step in 1...steps {
                let progress = CGFloat(step) / CGFloat(steps)
                drag(button, to: CGPoint(x: start.x + (destination.x - start.x) * progress,
                                        y: start.y + (destination.y - start.y) * progress))
                await pause(0.006)
                targetStayedStill = targetStayedStill && unchanged(identifier, from: baseline)
            }
            check(session != nil && button.isTrackingPointer,
                  "\(name): real source button owns the drag")
            check(intent?.candidate == .application(targetID), "\(name): icon overlap acquires the target")
            await pause(0.55) // No additional mouseDragged event: stationary dwell must work.
            check(intent?.isReady == true && intent?.candidate == .application(targetID),
                  "\(name): stationary overlap arms folder creation")
            check(value(root, "openFolderID", as: UUID.self) == nil,
                  "\(name): short dwell keeps the folder closed")
            check((selectionLayer(identifier)?.presentation()?.opacity
                   ?? selectionLayer(identifier)?.opacity ?? 0) > 0.5,
                  "\(name): merge-ready target shows the white rounded frame")
            check(targetStayedStill && unchanged(identifier, from: baseline),
                  "\(name): target never moves away during approach or dwell")
            try await cancel(button)
        }
    }

    private func checkDirectOverlapAndCommit() async throws {
        try await openFixture()
        sourceID = references[0].identity
        let identifier = LauncherLayoutItemIdentifier.application(targetID)
        let baseline = frames(identifier)!
        let destination = center(baseline.icon)
        let button = press()
        drag(button, to: destination)
        check(intent?.candidate == .application(targetID), "one input event acquires its actual icon target")
        await pause(0.55)
        check(intent?.isReady == true && unchanged(identifier, from: baseline),
              "direct stationary overlap arms without moving the target")
        check(value(root, "openFolderID", as: UUID.self) == nil && button.isTrackingPointer,
              "short merge dwell keeps the folder closed while the real drag remains active")
        check((selectionLayer(identifier)?.presentation()?.opacity
               ?? selectionLayer(identifier)?.opacity ?? 0) > 0.5,
              "merge-ready state uses the white rounded target frame")

        await release(button, at: destination)
        let document = try persisted()
        let created = folders(document)
        check(created.count == 1, "mouseUp on a ready target creates exactly one closed folder")
        check(value(root, "openFolderID", as: UUID.self) == nil,
              "normal folder creation does not open the new folder")
        if let folder = created.first {
            check(folder.applications.map(\.identity) == [targetID, sourceID!],
                  "new folder orders the target first and dragged application second")
            check(folder.customTitle == "Untitled",
                  "new folder persists the native Untitled name")
            check(entry(.folder(folder.id)).flatMap { value($0, "item", as: ResolvedLaunchpadItem.self) }?
                .displayName == "Untitled", "new folder displays Untitled")
        }
        verifyOneCommit(document)
        await pause(0.5)
        check(try persisted() == document, "release leaves no delayed second merge or commit")
    }

    private func checkSpringOpenAfterTwoSeconds() async throws {
        try await openFixture()
        sourceID = references[0].identity
        let destination = center(frames(.application(targetID))!.icon)
        let button = press()
        drag(button, to: destination)

        await pause(0.55)
        check(intent?.isReady == true, "spring-open test reaches merge-ready state")
        check(value(root, "openFolderID", as: UUID.self) == nil,
              "folder is still closed after the short merge dwell")

        await pause(1.60)
        let openedID: UUID? = value(root, "openFolderID", as: UUID.self)
        check(openedID != nil && button.isTrackingPointer,
              "continuous two-second overlap spring-opens without ending the real drag")

        let panel: CGRect = value(root, "folderPanelFrame")!
        let dropPoint = CGPoint(x: panel.midX, y: panel.midY)
        drag(button, to: dropPoint)
        await release(button, at: dropPoint)
        let document = try persisted()
        let created = folders(document)
        check(created.count == 1, "spring-open drop persists exactly one folder")
        check(value(root, "openFolderID", as: UUID.self) == created.first?.id,
              "spring-open folder remains open after dropping inside it")
        verifyOneCommit(document)
    }

    private func checkLeavingAndRestart() async throws {
        try await openFixture()
        sourceID = references[0].identity
        let destination = center(frames(.application(targetID))!.icon)
        let button = press()
        drag(button, to: destination)
        await pause(0.12)
        let outsideGrid = CGPoint(x: metrics.contentFrame.midX, y: metrics.contentFrame.maxY + 12)
        drag(button, to: outsideGrid)
        await pause(0.55)
        check(intent?.candidate == nil && intent?.isReady == false,
              "leaving before dwell clears candidate and cannot arm later")
        await release(button, at: outsideGrid)
        check(try persisted() == fixture, "release outside after leaving does not create a folder")

        try await openFixture()
        let nextID = references[targetIndex + 2].identity
        let nextPoint = center(frames(.application(nextID))!.icon)
        let switching = press()
        drag(switching, to: destination)
        await pause(0.23)
        drag(switching, to: nextPoint)
        check(intent?.candidate == .application(nextID), "B to C switches the pending candidate")
        await pause(0.26)
        check(intent?.candidate == .application(nextID) && intent?.isReady == false,
              "B's expired deadline cannot arm C before C's own dwell")
        await pause(0.25)
        check(intent?.candidate == .application(nextID) && intent?.isReady == true,
              "C arms only after its own stationary dwell")
        try await cancel(switching)

        try await openFixture()
        let cancelled = press()
        drag(cancelled, to: destination)
        await pause(0.10)
        try await cancel(cancelled)
        check(folders(try persisted()).isEmpty, "cancelling pending dwell cannot create a late folder")
    }

    private func checkReorderAndOffset() async throws {
        try await openFixture()
        sourceID = references[0].identity
        let baseline = frames(.application(targetID))!
        let destination = center(baseline.icon)
        let quick = press()
        drag(quick, to: destination)
        await release(quick, at: destination)
        let quickDocument = try persisted()
        check(folders(quickDocument).isEmpty, "quick release over an icon does not create a folder")
        check(quickDocument.items != fixture.items, "quick release still commits a reorder")
        verifyOneCommit(quickDocument)

        try await openFixture()
        let passing = press()
        drag(passing, to: destination)
        await pause(0.06)
        // The lower cell gutter is an insertion location, outside icon overlap.
        let gutter = CGPoint(x: baseline.cell.midX, y: baseline.cell.minY + 6)
        drag(passing, to: gutter)
        await pause(0.3)
        check(intent?.candidate?.isInsertion == true,
              "passing through the icon into its gutter selects reorder")
        check(frames(.application(targetID)) != baseline,
              "stationary gutter allows the reorder preview to move the neighbor")
        await release(passing, at: gutter)
        let reordered = try persisted()
        check(folders(reordered).isEmpty && reordered.items != fixture.items,
              "fast pass followed by gutter drop reorders without a folder")
        verifyOneCommit(reordered)

        try await openFixture()
        let sourceFrames = frames(.application(sourceID))!
        let offset = CGVector(dx: sourceFrames.icon.width * 0.26, dy: -sourceFrames.icon.height * 0.20)
        let offsetButton = press(offset: offset)
        let offsetDestination = CGPoint(x: destination.x + offset.dx, y: destination.y + offset.dy)
        drag(offsetButton, to: offsetDestination)
        await pause(0.55)
        check(intent?.candidate == .application(targetID) && intent?.isReady == true,
              "off-center mouseDown uses dragged-icon geometry for folder intent")
        check(unchanged(.application(targetID), from: baseline), "off-center grab does not displace its target")
        try await cancel(offsetButton)
    }

    private func checkExistingFolder() async throws {
        let originalFixture = fixture
        var items = references.map(LauncherLayoutItem.application)
        let folder = LauncherFolder(customTitle: "Kept Name", applications: [references[targetIndex], references.last!])
        items[targetIndex] = .folder(folder)
        items.removeLast()
        try await openFixture(LauncherLayoutDocument(revision: 950, items: items))
        sourceID = references[0].identity
        let folderButton = descendants(root).compactMap { $0 as? FolderTileButton }
            .first { $0.folderID == folder.id }
        check(folderButton != nil, "existing folder has its real FolderTileButton")
        let baseline = frames(.folder(folder.id))!
        let destination = center(baseline.icon)
        let button = press()
        drag(button, to: destination)
        await pause(0.55)
        check(intent?.candidate == .folder(folder.id) && intent?.isReady == true,
              "existing folder arms as an add target after stationary dwell")
        check(unchanged(.folder(folder.id), from: baseline), "existing folder stays in place while armed")
        check(value(root, "openFolderID", as: UUID.self) == nil && button.isTrackingPointer,
              "short dwell over an existing folder keeps it closed")
        await release(button, at: destination)
        let document = try persisted()
        let result = folders(document)
        check(result.count == 1 && result.first?.id == folder.id, "add preserves the existing folder identity")
        check(result.first?.applications.map(\.identity) == folder.applications.map(\.identity) + [sourceID!],
              "existing folder appends the dragged application exactly once")
        check(result.first?.customTitle == "Kept Name", "adding an application preserves a custom folder name")
        check(value(root, "openFolderID", as: UUID.self) == nil,
              "adding to an existing folder by mouseUp leaves it closed")
        verifyOneCommit(document)
        fixture = originalFixture
    }

    private func run() async throws {
        let discovery = await AppCatalogActor().refreshOutcome()
        precondition(discovery.completeness == .complete, "Needs a complete installed-app catalog")
        references = discovery.applications.map(LauncherApplicationReference.init(application:))
        fixture = LauncherLayoutDocument(revision: 900, items: references.map(LauncherLayoutItem.application))
        try await openFixture()
        precondition(metrics.columns >= 5 && metrics.rows >= 3 && references.count >= metrics.columns * 3,
                     "Needs an interior target and at least three complete app rows")
        targetIndex = metrics.columns + metrics.columns / 2
        try await checkEightApproaches()
        try await checkDirectOverlapAndCommit()
        try await checkSpringOpenAfterTwoSeconds()
        try await checkLeavingAndRestart()
        try await checkReorderAndOffset()
        try await checkExistingFolder()
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

@main
struct FolderMergeCheck {
    @MainActor static func main() {
        precondition(ProcessInfo.processInfo.environment["OPENLAUNCHPAD_LAYOUT_PATH"]?.hasPrefix("/private/tmp/") == true,
                     "Use an isolated layout file under /private/tmp")
        let app = NSApplication.shared
        let delegate = FolderMergeCheckDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
