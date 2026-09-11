import AppKit
import DisplayCore

@MainActor
final class LaunchpadWindowController: NSWindowController {
    private let displayResolver =
        ScreenDisplayContextResolver()

    private let menuBarBackdrop = MenuBarBackdropWindow()

    private var targetDisplayID:
        CGDirectDisplayID = 0

    private var previousFrontmostApplication:
        NSRunningApplication?

    convenience init() {
        let screen =
            DisplaySelector.screenContainingMouse()
                ?? NSScreen.main

        let resolver =
            ScreenDisplayContextResolver()

        let display =
            screen.map(
                resolver.resolve
            )
            ?? DisplayContext(
                displayID: 0,
                frame:
                    CGRect(
                        x: 0,
                        y: 0,
                        width: 1080,
                        height: 760
                    ),
                visibleFrame:
                    CGRect(
                        x: 0,
                        y: 0,
                        width: 1080,
                        height: 760
                    ),
                backingScaleFactor: 1
            )

        let localFrame =
            CGRect(
                origin: .zero,
                size: display.frame.size
            )

        let window =
            LaunchpadWindow(
                contentRect: display.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false

        // Keep Dock above the interactive launcher. Only the desktop's top
        // continuation is above system menu windows; both use the same pixels.
        window.level = .floating

        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]

        window.animationBehavior = .none

        window.contentView =
            LaunchpadRootView(
                frame: localFrame,
                displayContext: display
            )

        self.init(
            window: window
        )

        targetDisplayID =
            display.displayID

        window.onDidHide = {
            [weak self] in

            guard let self else {
                return
            }

            self.menuBarBackdrop.dismiss()

            self
                .restorePreviousFrontmostApplicationIfNeeded()
        }

        NotificationCenter.default.addObserver(
            self,
            selector:
                #selector(
                    displayConfigurationDidChange
                ),
            name:
                NSApplication
                    .didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApplication.shared
        )
    }

    override func showWindow(
        _: Any?
    ) {
        presentFromLauncher()
    }

    func togglePresentationFromLauncher() {
        guard
            let window =
                window as? LaunchpadWindow
        else {
            return
        }

        if window.isPresentedOrPresenting {
            window.dismiss()
        } else {
            presentFromLauncher()
        }
    }

    func restoreSystemPresentationForTermination() {
        menuBarBackdrop.dismiss()
    }

    private func presentFromLauncher() {
        guard
            let window =
                window as? LaunchpadWindow
        else {
            return
        }

        // Reset only on a new opening, not on live display changes or an
        // activation request while already visible. Do it before ordering front
        // so no frame of the previous query/results appears during the fade-in.
        if !window.isPresentedOrPresenting {
            (window.contentView as? LaunchpadRootView)?.resetForNewPresentation()
        }

        let ownPID =
            ProcessInfo.processInfo
                .processIdentifier

        if let frontmost =
            NSWorkspace.shared
                .frontmostApplication,
           frontmost.processIdentifier
                != ownPID
        {
            previousFrontmostApplication =
                frontmost
        }

        if let screen = DisplaySelector.screenContainingMouse() ?? window.screen {
            updateDisplay(screen)
            presentMenuBarBackdrop(on: screen)
        }

        // The embedded agent is launched with `configuration.activates = false`.
        // Activate it BEFORE making the launcher window key. Otherwise AppKit can
        // consume the first background click only to activate the application,
        // and the click never reaches LaunchpadRootView.mouseDown(_:).
        NSApplication.shared.activate()

        window.present()
    }

    private func presentMenuBarBackdrop(on screen: NSScreen) {
        let rootView = window?.contentView as? LaunchpadRootView
        menuBarBackdrop.present(
            on: screen,
            desktopImage: rootView?.desktopImage,
            wallpaperImage: rootView?.desktopBackdropImage
        )
        (window as? LaunchpadWindow)?.synchronizedBackdropLayer = menuBarBackdrop.transitionLayer
    }

    private func updateDisplay(_ screen: NSScreen) {
        let display = displayResolver.resolve(screen)
        targetDisplayID = display.displayID
        window?.setFrame(display.frame, display: false)
        (window?.contentView as? LaunchpadRootView)?
            .prepareForPresentation(displayContext: display)
    }

    @objc private func applicationDidResignActive() {
        // Dock clicks / Command-Tab must give the destination application its
        // menu immediately. Never leave the top surface attached to another app.
        menuBarBackdrop.dismiss()
        guard let window = window as? LaunchpadWindow, window.isPresentedOrPresenting else { return }
        window.dismiss()
    }

    private func restorePreviousFrontmostApplicationIfNeeded() {
        let ownPID =
            ProcessInfo.processInfo
                .processIdentifier

        let agentIsStillFrontmost =
            NSWorkspace.shared
                .frontmostApplication?
                .processIdentifier
                == ownPID

        guard agentIsStillFrontmost else {
            previousFrontmostApplication =
                nil
            return
        }

        NSApplication.shared.deactivate()

        if let previousFrontmostApplication,
           !previousFrontmostApplication
                .isTerminated
        {
            _ =
                previousFrontmostApplication
                    .activate(
                        options: []
                    )
        }

        previousFrontmostApplication =
            nil
    }

    @objc
    private func displayConfigurationDidChange() {
        let targetScreen =
            DisplaySelector.screen(
                with: targetDisplayID
            )
            ?? DisplaySelector
                .screenContainingMouse()

        guard let targetScreen else {
            return
        }

        updateDisplay(targetScreen)

        guard
            let launchpadWindow =
                window as? LaunchpadWindow,
            launchpadWindow
                .isPresentedOrPresenting
        else {
            return
        }

        presentMenuBarBackdrop(on: targetScreen)
    }
}
