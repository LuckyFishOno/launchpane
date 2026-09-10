import AppKit

@MainActor
final class OpenLaunchpadAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: LaunchpadWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        let windowController = LaunchpadWindowController()
        self.windowController = windowController
        windowController.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
