import AppKit

// LAUNCHPANE_DOCK_AGENT_ARCHITECTURE_V1
//
// This process is intentionally tiny and short-lived.
//
// The Dock tile points at LaunchPane.app, but all persistent UI lives in
// LaunchPaneAgent.app. Both processes use accessory activation policy, so
// neither process owns a normal macOS menu bar. The agent has a distinct bundle
// identifier, so keeping the launcher tile in the Dock does not expose the
// agent's running state, Hide/Quit menu items, or running indicator.

private enum DockLauncherIPC {
    static let agentBundleIdentifier =
        "org.launchpane.LaunchPaneAgent"

    static let toggleNotification =
        Notification.Name(
            "org.launchpane.LaunchPaneAgent.toggle"
        )

    static func agentApplicationURL() -> URL? {
        let embeddedURL =
            Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Library")
                .appendingPathComponent("LoginItems")
                .appendingPathComponent(
                    "LaunchPaneAgent.app"
                )

        if FileManager.default.fileExists(
            atPath: embeddedURL.path
        ) {
            return embeddedURL
        }

        let siblingURL =
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "LaunchPaneAgent.app"
                )

        if FileManager.default.fileExists(
            atPath: siblingURL.path
        ) {
            return siblingURL
        }

        return nil
    }
}

@MainActor
private final class DockLauncherDelegate:
    NSObject,
    NSApplicationDelegate {
    func applicationDidFinishLaunching(
        _: Notification
    ) {
        dispatchToggle()
    }

    private func dispatchToggle() {
        let runningAgents =
            NSRunningApplication
                .runningApplications(
                    withBundleIdentifier:
                        DockLauncherIPC
                            .agentBundleIdentifier
                )
                .filter {
                    !$0.isTerminated
                }

        if !runningAgents.isEmpty {
            DistributedNotificationCenter
                .default()
                .postNotificationName(
                    DockLauncherIPC
                        .toggleNotification,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )

            terminateLauncherSoon()
            return
        }

        guard
            let agentURL =
                DockLauncherIPC
                    .agentApplicationURL()
        else {
            fputs(
                "LaunchPane: embedded agent was not found.\n",
                stderr
            )
            NSSound.beep()
            NSApplication.shared.terminate(nil)
            return
        }

        let configuration =
            NSWorkspace.OpenConfiguration()

        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false

        NSWorkspace.shared.openApplication(
            at: agentURL,
            configuration: configuration
        ) { _, error in
            let errorMessage =
                error?.localizedDescription

            DispatchQueue.main.async {
                if let errorMessage {
                    fputs(
                        "LaunchPane: failed to launch agent: "
                            + errorMessage
                            + "\n",
                        stderr
                    )
                    NSSound.beep()
                }

                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func terminateLauncherSoon() {
        Task { @MainActor in
            try? await Task.sleep(
                for: .milliseconds(24)
            )
            NSApplication.shared.terminate(nil)
        }
    }
}

let application = NSApplication.shared
private let delegate = DockLauncherDelegate()

application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
