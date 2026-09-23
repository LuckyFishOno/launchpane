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

        window.onDidHide = { [weak self] in

            guard let self else {
                return
            }

            self.menuBarBackdrop.dismiss()

            // The window is fully ordered out at this point. Drop decoded
            // Retina icons and compositor page trees while the agent is idle.
            (self.window?.contentView as? LaunchpadRootView)?
                .releasePresentationResourcesForIdle()

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
                != ownPID {
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
        // LAUNCHPANE_FOLDER_EXTRACTION_ACTIVATION_SHIELD_V21
        // LAUNCHPANE_FOLDER_DRAG_RELEASE_OWNERSHIP_V22
        //
        // Folder drag can replace/rebuild its AppKit hit-target surface while the
        // physical pointer gesture or its landing commit still owns the original
        // button. On an accessory/LSUIElement app, that internal ownership handoff
        // can produce a transient didResignActive even though the user did not
        // click the Dock or Command-Tab. Treat only the root view's explicitly
        // reported internal handoff interval as non-dismissal; ordinary external
        // deactivation behavior remains unchanged.
        if let rootView = window?.contentView as? LaunchpadRootView,
           rootView.suppressesResignActiveDismissal {
            NSApplication.shared.activate()
            window?.makeKey()
            return
        }

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
                .isTerminated {
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

        // Screen notifications can arrive while the launcher is hidden.
        // Do not rehydrate a full Retina render tree in the background; the
        // next presentation resolves the mouse screen and display scale again.
        guard
            let launchpadWindow =
                window as? LaunchpadWindow,
            launchpadWindow
                .isPresentedOrPresenting
        else {
            return
        }

        updateDisplay(targetScreen)
        presentMenuBarBackdrop(on: targetScreen)
    }
}
