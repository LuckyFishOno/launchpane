// Exercises NSWindow event dispatch, including the hidden source view that
// direct button.mouseUp calls bypass. Uses only app-local synthetic NSEvents.
import AppCore
import AppKit
import QuartzCore

@MainActor
final class PointerOwnershipCheckDelegate: NSObject, NSApplicationDelegate {
    private var failures = 0
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private var controller: LaunchpadWindowController!
    private var root: LaunchpadRootView {
        guard let root = controller.window?.contentView as? LaunchpadRootView else {
            fatalError("Expected the launcher window to contain LaunchpadRootView")
        }
        return root
    }
    private let folderID = UUID()
    private var fixture = LauncherLayoutDocument()
    private var references: [LauncherApplicationReference] = []
    private var layoutURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAUNCHPANE_LAYOUT_PATH"]!)
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
    private func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") \(message)")
        if !condition { failures += 1 }
    }
    private func pause(_ seconds: Double = 0.05) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
    @discardableResult
    private func until(_ message: String, _ predicate: () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + 5
        while !predicate(), CACurrentMediaTime() < deadline { await pause(0.015) }
        let result = predicate()
        check(result, message)
        return result
    }
    private func send(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) {
        window.sendEvent(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )!)
    }
    private func send(_ type: NSEvent.EventType, at point: CGPoint) {
        send(type, at: root.convert(point, to: nil), window: controller.window!)
    }
    private func checkWindowDispatch() {
        let window = LaunchpadWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = PointerTrackingTileButton(accessibilityLabel: "Source", accessibilityHelp: "Test")
        button.frame = NSRect(x: 100, y: 100, width: 60, height: 60)
        window.contentView!.addSubview(button)
        window.makeKeyAndOrderFront(nil)
        var releases = 0
        var drags = 0
        var cancellations = 0
        button.onPointerUp = { _ in releases += 1 }
        button.onPointerDragged = { _ in drags += 1 }
        button.onPointerCancelled = { cancellations += 1 }
        for hidden in [false, true] {
            button.isHidden = false
            button.isEnabled = true
            send(.leftMouseDown, at: CGPoint(x: 130, y: 130), window: window)
            send(.leftMouseDragged, at: CGPoint(x: 200, y: 130), window: window)
            button.isHidden = hidden
            button.isEnabled = !hidden
            let before = drags
            send(.leftMouseDragged, at: CGPoint(x: 240, y: 130), window: window)
            check(drags == before + 1, "hidden=\(hidden): original owner receives subsequent drag")
            let beforeRelease = releases
            send(.leftMouseUp, at: CGPoint(x: 450, y: 130), window: window)
            check(releases == beforeRelease + 1 && !button.isTrackingPointer,
                  "hidden=\(hidden): outside-window release arrives exactly once")
            send(.leftMouseUp, at: CGPoint(x: 450, y: 130), window: window)
            check(releases == beforeRelease + 1, "duplicate release does not commit again")
            button.cancelPointerTracking()
        }
        button.isHidden = false
        button.isEnabled = true
        send(.leftMouseDown, at: CGPoint(x: 130, y: 130), window: window)
        button.removeFromSuperview()
        let before = releases
        send(.leftMouseUp, at: CGPoint(x: 240, y: 130), window: window)
        check(cancellations >= 1 && releases == before && !button.isTrackingPointer,
              "detached owner cancels instead of receiving a stale release")
        window.orderOut(nil)
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
        await until("fixture loaded") { value(root, "isLoadingApplications") == false }
        root.layoutSubtreeIfNeeded()
        await pause(0.3)
        let folder = root.subviews.compactMap { $0 as? FolderTileButton }.first { $0.folderID == folderID }!
        let point = root.convert(CGPoint(x: folder.bounds.midX, y: folder.bounds.midY), from: folder)
        send(.leftMouseDown, at: point)
        send(.leftMouseUp, at: point)
        await pause(0.5)
        check(value(root, "openFolderID", as: UUID.self) == folderID, "folder opens through window dispatch")
    }
    private func checkFolderDrop(crossPage: Bool, duringTransition: Bool = false) async throws {
        try await openFixture()
        // Loading may reconcile the installed-app catalog and advance the fixture
        // revision. Measure only writes caused by this pointer interaction.
        let beforeDrag = try JSONDecoder().decode(
            LauncherLayoutDocument.self, from: Data(contentsOf: layoutURL)
        )
        let presentations: [AppTilePresentation] = value(root, "folderPresentations")!
        let source = presentations[0]
        let start = root.convert(
            CGPoint(x: source.button.bounds.midX, y: source.button.bounds.midY), from: source.button
        )
        send(.leftMouseDown, at: start)
        let panel: CGRect = value(root, "folderPanelFrame")!
        let target = crossPage
            ? CGPoint(x: panel.maxX - 2, y: start.y)
            : presentations[2].tileLayer.position
        send(.leftMouseDragged, at: target)
        check(value(root, "folderItemDragSession", as: Any.self) != nil, "folder drag starts through window dispatch")
        if crossPage {
            await until("folder edge turn reached requested phase") {
                let context: Any? = value(root, "folderItemDragSession", as: Any.self)
                let inFlight: Bool = context.flatMap { value($0, "isEdgePageTurnInFlight") } ?? false
                let page: Int = value(root, "folderPage") ?? 0
                return duringTransition ? inFlight : page == 1 && !inFlight
            }
        }
        let folderChrome: CALayer? = value(root, "folderContentAnimationLayer")
        let landingPresentations: [AppTilePresentation] = value(root, "folderPresentations")!
        let beforeRelease = try Data(contentsOf: layoutURL)
        let beforeReleaseDocument = try JSONDecoder().decode(LauncherLayoutDocument.self, from: beforeRelease)
        check(beforeReleaseDocument == beforeDrag, "folder drag preview does not persist before release")
        send(.leftMouseUp, at: target)
        let settled = await until("folder drop settles without Escape") {
            value(root, "folderItemDragSession", as: Any.self) == nil
                && value(root, "isCommittingLayout") == false
                && value(root, "dragStateMachine", as: LauncherDragStateMachine.self)?.state == .idle
        }
        check(!source.button.isTrackingPointer, "source pointer tracking ended")
        if !settled {
            let state = value(root, "dragStateMachine", as: LauncherDragStateMachine.self)
            let committing = value(root, "isCommittingLayout", as: Bool.self)
            let folderDrag = value(root, "folderItemDragSession", as: Any.self)
            print("DIAGNOSTIC state=\(String(describing: state)) "
                + "committing=\(String(describing: committing)) folderDrag=\(String(describing: folderDrag))")
        }
        if settled {
            let document = try JSONDecoder().decode(LauncherLayoutDocument.self, from: Data(contentsOf: layoutURL))
            let folder = document.items.compactMap { if case let .folder(folder) = $0 { folder } else { nil } }.first!
            check(document.revision == beforeDrag.revision + 1,
                  "folder reorder committed exactly once (before=\(beforeDrag.revision), after=\(document.revision))")
            check(Set(folder.applications) == Set(references), "folder reorder preserves every app")
            check(folder.applications != references, "folder order changed")
            let current: [AppTilePresentation] = value(root, "folderPresentations")!
            check(value(root, "folderContentAnimationLayer", as: CALayer.self) === folderChrome,
                  "drop keeps the existing folder panel instead of rebuilding it")
            if !duringTransition {
                check(current.allSatisfy { presentation in
                    landingPresentations.contains { $0 === presentation }
                }, "landing preserves the displayed icon layers and their full-resolution contents")
            }
            check(current.allSatisfy { !$0.button.isHidden && $0.button.isEnabled && $0.button.window != nil },
                  "committed folder has usable hit targets")
            // Start another drag immediately: merely seeing a landing is insufficient.
            let next = current.first { $0.button.application.id == source.button.application.id }!
            let point = root.convert(CGPoint(x: next.button.bounds.midX, y: next.button.bounds.midY), from: next.button)
            send(.leftMouseDown, at: point)
            send(.leftMouseDragged, at: CGPoint(x: point.x + 10, y: point.y))
            check(value(root, "folderItemDragSession", as: Any.self) != nil, "next drag starts without Escape")
            let nextContext: Any? = value(root, "folderItemDragSession", as: Any.self)
            check(nextContext.flatMap { value($0, "sourceAbsoluteIndex", as: Int.self) }
                    == folder.applications.firstIndex { $0.identity == next.button.application.id },
                  "reused button starts from its committed index")
            next.button.cancelOperation(nil)
            await pause(0.4)
        }
    }
    private func run() async throws {
        checkWindowDispatch()
        let discovery = await AppCatalogActor().refreshOutcome()
        references = discovery.applications.prefix(40).map(LauncherApplicationReference.init(application:))
        precondition(references.count == 40, "Needs 40 installed applications for a multi-page folder")
        let remaining = discovery.applications.dropFirst(40).map {
            LauncherLayoutItem.application(LauncherApplicationReference(application: $0))
        }
        fixture = LauncherLayoutDocument(revision: 100, items: [.folder(LauncherFolder(
            id: folderID, customTitle: "Pointer Regression", applications: references
        ))] + remaining)
        try await checkFolderDrop(crossPage: false)
        try await checkFolderDrop(crossPage: true)
        try await checkFolderDrop(crossPage: true, duringTransition: true)
    }
    func applicationDidFinishLaunching(_: Notification) {
        Task { @MainActor in
            do { try await run() } catch { check(false, "unexpected error: \(error)") }
            controller?.restoreSystemPresentationForTermination()
            controller?.close()
            previousApp?.activate(options: [])
            print("POINTER OWNERSHIP: \(failures) failures")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

@main struct PointerOwnershipCheck {
    @MainActor static func main() {
        precondition(ProcessInfo.processInfo.environment["LAUNCHPANE_LAYOUT_PATH"]?.hasPrefix("/private/tmp/") == true)
        let app = NSApplication.shared
        let delegate = PointerOwnershipCheckDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
