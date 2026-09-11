import AppKit

@MainActor
final class OpenLaunchpadAppDelegate:
    NSObject,
    NSApplicationDelegate
{
    private static let toggleNotification =
        Notification.Name(
            "org.openlaunchpad.OpenLaunchpadAgent.toggle"
        )

    private var windowController:
        LaunchpadWindowController?

    private var pendingToggleCount = 0

    override init() {
        super.init()

        DistributedNotificationCenter
            .default()
            .addObserver(
                self,
                selector:
                    #selector(
                        toggleRequested(_:)
                    ),
                name:
                    Self.toggleNotification,
                object: nil,
                suspensionBehavior:
                    .deliverImmediately
            )
    }

    func applicationDidFinishLaunching(
        _: Notification
    ) {
        NSApplication.shared
            .setActivationPolicy(
                .accessory
            )

        let windowController =
            LaunchpadWindowController()

        self.windowController =
            windowController

        windowController.showWindow(nil)

        if pendingToggleCount % 2 == 1 {
            windowController
                .togglePresentationFromLauncher()
        }

        pendingToggleCount = 0
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _: NSApplication
    ) -> Bool {
        false
    }

    func applicationWillTerminate(
        _: Notification
    ) {
        windowController?
            .restoreSystemPresentationForTermination()

        DistributedNotificationCenter
            .default()
            .removeObserver(
                self,
                name:
                    Self.toggleNotification,
                object: nil
            )
    }

    @objc
    private func toggleRequested(
        _: Notification
    ) {
        guard let windowController else {
            pendingToggleCount &+= 1
            return
        }

        windowController
            .togglePresentationFromLauncher()
    }
}
