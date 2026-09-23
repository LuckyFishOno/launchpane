// Standalone AppKit regression harness. Compile alongside Sources/LaunchPane
// (excluding main.swift), linking AppCore, DisplayCore and LayoutCore frameworks.
// Run with LAUNCHPANE_LAYOUT_PATH pointing to a temporary JSON file; do not
// use the user's layout store. No global input injection is needed.
import AppKit
import DisplayCore
import QuartzCore

@MainActor
final class SearchReopenCheckDelegate: NSObject, NSApplicationDelegate {
    private var controller: LaunchpadWindowController!
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private var failures = 0
    private var initialTileCount = 0
    private var root: LaunchpadRootView {
        guard let root = controller.window?.contentView as? LaunchpadRootView else {
            fatalError("Expected the launcher window to contain LaunchpadRootView")
        }
        return root
    }
    private var search: LaunchpadSearchField {
        descendants(root).compactMap { $0 as? LaunchpadSearchField }.first!
    }
    private var textField: NSTextField {
        descendants(search).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    }
    private var settingsButton: NSButton? {
        descendants(search).compactMap { $0 as? NSButton }.first { $0.menu != nil }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") \(message)")
        if !condition { failures += 1 }
    }

    private func pause(_ seconds: Double = 0.5) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func open() {
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func input(_ query: String) {
        search.focus(in: controller.window)
        search.stringValue = query
        search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        root.layoutSubtreeIfNeeded()
    }

    private func clickOutside() {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 2, y: 2),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.window!.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
        root.mouseDown(with: event)
    }

    private func checkIdle(_ scenario: String) {
        root.layoutSubtreeIfNeeded()
        search.layoutSubtreeIfNeeded()
        check(search.stringValue.isEmpty, "\(scenario): query cleared")
        check(textField.currentEditor() == nil, "\(scenario): no field editor/caret")
        check(controller.window!.firstResponder === root, "\(scenario): keyboard focus restored to grid")
        let placeholder = descendants(search).compactMap { $0 as? NSTextField }
            .first { !$0.isEditable && $0.stringValue == "Search" }
        check(placeholder?.isHidden == false, "\(scenario): Search placeholder visible")
        let motionLayer = search.subviews.first { child in
            child.subviews.contains { $0 is NSImageView }
        }?.layer
        check(abs(motionLayer?.sublayerTransform.m41 ?? 0) > 1, "\(scenario): magnifier/placeholder centered")
        check(motionLayer?.animationKeys()?.isEmpty ?? true, "\(scenario): old focus animation removed")
        check(descendants(root).filter { $0 is AppTileButton }.count == initialTileCount,
              "\(scenario): initial application grid restored")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = LaunchpadWindowController()
        open()
        Task { @MainActor in
            for _ in 0..<30 {
                if !descendants(root).filter({ $0 is AppTileButton }).isEmpty { break }
                await pause(0.1)
            }
            initialTileCount = descendants(root).filter { $0 is AppTileButton }.count
            check(initialTileCount > 1, "application catalog loaded")
            check(settingsButton != nil, "settings button exists")
            check(abs((settingsButton?.frame.maxX ?? 0) - (search.bounds.maxX - 10)) <= 1,
                  "settings button is at the search field's right edge")
            check(settingsButton?.menu?.items.map(\.title) == ["Reset Launchpad"],
                  "settings menu has only Reset Launchpad")
            input("saf")
            check(search.stringValue == "saf", "partial search entered")
            check(descendants(root).filter { $0 is AppTileButton }.count < initialTileCount,
                  "search results are filtered")

            // Display geometry changes are not a new opening; don't lose input.
            let display = ScreenDisplayContextResolver().resolve(controller.window!.screen!)
            root.prepareForPresentation(displayContext: display)
            check(search.stringValue == "saf", "display preparation preserves an active search")

            clickOutside()
            await pause()
            check(!controller.window!.isVisible, "outside click dismisses launcher")
            open()
            await pause()
            checkIdle("normal reopen")

            // Focus animation and dismissal are both still in flight here.
            input("cal")
            clickOutside()
            open()
            await pause()
            checkIdle("rapid reopen")

            search.focus(in: controller.window)
            guard let editor = textField.currentEditor() as? NSTextView else {
                fatalError("Expected an active NSTextView field editor before testing unfinished IME input")
            }
            editor.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            check(editor.hasMarkedText(), "unfinished IME input exists")
            clickOutside()
            open()
            await pause()
            checkIdle("IME reopen")

            // Resetting does not disable search for the next session.
            search.focus(in: controller.window)
            search.insertText("saf")
            await pause(0.1)
            check(search.stringValue == "saf", "typing works after reset")
            controller.showWindow(nil)
            check(search.stringValue == "saf", "showing an already visible launcher preserves search")
            controller.togglePresentationFromLauncher()
            await pause()
            controller.restoreSystemPresentationForTermination()
            previousApp?.activate(options: [])
            print("SEARCH REOPEN: \(failures) failures")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

@main
struct SearchReopenCheck {
    @MainActor static func main() {
        precondition(ProcessInfo.processInfo.environment["LAUNCHPANE_LAYOUT_PATH"] != nil,
                     "Use an isolated layout path for this test")
        let app = NSApplication.shared
        let delegate = SearchReopenCheckDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
