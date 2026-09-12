// Drives the real AppKit pointer owner with isolated persisted layouts.
// Mirror is read-only observation of private state, not a replacement drag path.
import AppCore
import AppKit
import LayoutCore
import QuartzCore

@MainActor
final class CrossPageDragCheckDelegate: NSObject, NSApplicationDelegate {
    private var controller: LaunchpadWindowController!
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private var failures = 0
    private var fixture = LauncherLayoutDocument()
    private var sourceID: ApplicationIdentity!
    private var root: LaunchpadRootView { controller.window!.contentView as! LaunchpadRootView }
    private var layoutURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPENLAUNCHPAD_LAYOUT_PATH"]!)
    }
    private func value<T>(_ object: Any, _ key: String, as: T.Type = T.self) -> T? {
        guard let raw = Mirror(reflecting: object).children.first(where: { $0.label == key })?.value else { return nil }
        let mirror = Mirror(reflecting: raw)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return nil }
            return child.value as? T
        }
        return raw as? T
    }
    private var session: Any? {
        let raw = Mirror(reflecting: root).children.first { $0.label == "dragSession" }!.value
        return Mirror(reflecting: raw).children.first?.value
    }
    private var page: Int { value(root, "currentPage") ?? -1 }
    private var transitioning: Bool { session.flatMap { value($0, "isEdgePageTransitionActive") } ?? false }
    private var metrics: GridMetrics { value(root, "currentMetrics")! }
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") \(message)")
        if !condition { failures += 1 }
    }
    private func pause(_ seconds: Double = 0.1) async {
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
    private func openFixture() async throws {
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
    private func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: root.convert(point, to: nil),
                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: controller.window!.windowNumber, context: nil,
                          eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    private func edge(_ direction: Int) -> CGPoint {
        CGPoint(x: direction > 0 ? root.bounds.maxX - 2 : root.bounds.minX + 2,
                y: metrics.contentFrame.midY)
    }
    private func start() -> AppTileButton {
        let button = descendants(root).compactMap { $0 as? AppTileButton }
            .first { $0.application.id == sourceID }!
        let point = root.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        button.mouseDown(with: event(.leftMouseDown, at: point))
        button.mouseDragged(with: event(.leftMouseDragged, at: edge(1)))
        check(session != nil && button.isTrackingPointer, "real source button owns active drag")
        return button
    }
    private func sourcePage(in document: LauncherLayoutDocument) -> Int? {
        document.pages.firstIndex { items in items.contains { item in
            if case let .application(ref) = item { return ref.identity == sourceID }
            return false
        } }
    }
    private func persisted() throws -> LauncherLayoutDocument {
        try JSONDecoder().decode(LauncherLayoutDocument.self, from: Data(contentsOf: layoutURL))
    }
    private func settled() async {
        await until("drag and persistence settled") {
            session == nil && value(root, "isCommittingLayout") == false
                && value(root, "isFinishingDragVisuals") == false
        }
        root.layoutSubtreeIfNeeded()
        await pause(0.1)
    }
    private func verifyCommit(page expected: Int, _ message: String) throws {
        let document = try persisted()
        check(sourcePage(in: document) == expected, message)
        check(document.items.count == fixture.items.count, "no app lost or duplicated")
        check(document.pages[0].count == fixture.pages[0].count - 1, "source gap does not pull later apps")
        check(document.revision == fixture.revision + 1, "drop persisted exactly once")
        check(descendants(root).compactMap { $0 as? AppTileButton }
            .filter { $0.application.id == sourceID }.count == 1,
              "committed app has exactly one live pointer target")
    }
    private func run() async throws {
        let discovery = await AppCatalogActor().refreshOutcome()
        let items = discovery.applications.map { LauncherLayoutItem.application(LauncherApplicationReference(application: $0)) }
        precondition(items.count >= 16, "Needs at least 16 installed apps")
        sourceID = discovery.applications[0].id
        fixture = LauncherLayoutDocument(revision: 100, pages: [Array(items[0..<4]), Array(items[4..<8]),
                                                               Array(items[8..<12]), Array(items[12...])])

        try await openFixture()
        let held = start()
        if await until("stationary edge reaches third page", { page == 2 && !transitioning }) {
            check(held.isTrackingPointer && held.window != nil, "pointer owner survives two page changes")
            held.mouseUp(with: event(.leftMouseUp, at: edge(1)))
            await settled()
            try verifyCommit(page: 2, "edge mouseUp commits on third page")
            check(try persisted().pages[1] == fixture.pages[1], "intermediate page remains unchanged")
            await pause(0.6)
            check(page == 2 && session == nil, "mouseUp cancels the next dwell")
        }

        try await openFixture()
        let mid = start()
        if await until("edge transition began", { transitioning }) {
            mid.mouseUp(with: event(.leftMouseUp, at: edge(1)))
            check(session != nil, "mouseUp deferred during transition")
            await settled()
            try verifyCommit(page: 1, "mid-animation release commits incoming page")
        }

        try await openFixture()
        let returning = start()
        if await until("reached second page for reverse traversal", { page == 1 && !transitioning }) {
            returning.mouseDragged(with: event(.leftMouseDragged, at: edge(-1)))
            if await until("can return to original page", { page == 0 && !transitioning }) {
                check(returning.isTrackingPointer && returning.window != nil,
                      "return visit does not detach source pointer owner")
                returning.mouseUp(with: event(.leftMouseUp, at: edge(-1)))
                await settled()
                check(try persisted().pages == fixture.pages, "round trip to original slot is a no-op")
            }
        }

        try await openFixture()
        let cancelled = start()
        if await until("transition began before Escape", { transitioning }) {
            let incoming: Any = value(session!, "edgeIncomingSurface")!
            let outgoing: Any = value(session!, "edgeOutgoingSurface")!
            let incomingLayer: CALayer = value(incoming, "layer")!
            let outgoingLayer: CALayer = value(outgoing, "layer")!
            cancelled.cancelOperation(nil)
            await settled()
            await pause(0.6)
            check(page == 0 && session == nil, "Escape cancels pending transition and restores source page")
            check(try persisted().pages == fixture.pages, "Escape never persists preview")
            check(incomingLayer.superlayer == nil && outgoingLayer.superlayer == nil,
                  "rollback retires both exact transition trees")
        }

        // Existing partial pages are preserved; holding past the last one offers
        // one new page and then stops, rather than generating infinite empties.
        try await openFixture()
        let trailingPage = fixture.normalizedForPageCapacity(metrics.itemsPerPage).pages.count
        let trailing = start()
        if await until("held edge reaches a new trailing page", timeout: 12, { page == trailingPage && !transitioning }) {
            await pause(1.2)
            check(page == trailingPage && !transitioning, "holding on new last page stays bounded")
            trailing.mouseUp(with: event(.leftMouseUp, at: edge(1)))
            await settled()
            try verifyCommit(page: trailingPage, "drop persists newly created page")
        }

        // Make the final existing page exactly full: inserting here must push
        // its last app into a new page, not refill the source page's vacancy.
        let capacity = metrics.itemsPerPage
        if items.count > capacity {
            let prefix = Array(items.dropLast(capacity))
            let pages = stride(from: 0, to: prefix.count, by: capacity).map {
                Array(prefix[$0..<min($0 + capacity, prefix.count)])
            } + [Array(items.suffix(capacity))]
            fixture = LauncherLayoutDocument(revision: 200, pages: pages)
            try await openFixture()
            let destination = pages.count - 1
            let overflow = start()
            if await until("drag reaches full final page", timeout: 12, { page == destination && !transitioning }) {
                overflow.mouseUp(with: event(.leftMouseUp, at: edge(1)))
                await settled()
                try verifyCommit(page: destination, "dragged app remains on full destination page")
                let document = try persisted()
                check(document.pages.count == pages.count + 1, "overflow creates an additional page")
                check(document.pages.last == [pages.last!.last!], "only overflow advances to the new page")
            }
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run() } catch { check(false, "unexpected error: \(error)") }
            controller?.restoreSystemPresentationForTermination()
            controller?.close()
            previousApp?.activate(options: [])
            print("CROSS PAGE DRAG: \(failures) failures")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

@main
struct CrossPageDragCheck {
    @MainActor static func main() {
        precondition(ProcessInfo.processInfo.environment["OPENLAUNCHPAD_LAYOUT_PATH"]?.hasPrefix("/private/tmp/") == true,
                     "Use an isolated layout file under /private/tmp")
        let app = NSApplication.shared
        let delegate = CrossPageDragCheckDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
