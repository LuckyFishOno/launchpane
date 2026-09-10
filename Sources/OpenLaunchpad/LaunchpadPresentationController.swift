import AppKit
import DisplayCore

@MainActor
final class LaunchpadWindowController: NSWindowController {
    private let displayResolver = ScreenDisplayContextResolver()
    private var targetDisplayID: CGDirectDisplayID = 0

    convenience init() {
        let screen = DisplaySelector.screenContainingMouse() ?? NSScreen.main
        let resolver = ScreenDisplayContextResolver()
        let display = screen.map(resolver.resolve) ?? DisplayContext(
            displayID: 0,
            frame: CGRect(x: 0, y: 0, width: 1080, height: 760),
            visibleFrame: CGRect(x: 0, y: 0, width: 1080, height: 760),
            backingScaleFactor: 1
        )
        let localFrame = CGRect(origin: .zero, size: display.frame.size)
        let window = LaunchpadWindow(
            contentRect: display.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.animationBehavior = .utilityWindow
        window.contentView = LaunchpadRootView(frame: localFrame, displayContext: display)
        self.init(window: window)
        targetDisplayID = display.displayID

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        (window as? LaunchpadWindow)?.present()
    }

    @objc private func displayConfigurationDidChange() {
        let targetScreen = DisplaySelector.screen(with: targetDisplayID)
            ?? DisplaySelector.screenContainingMouse()
        guard let targetScreen else { return }

        let display = displayResolver.resolve(targetScreen)
        targetDisplayID = display.displayID
        window?.setFrame(display.frame, display: true)
        (window?.contentView as? LaunchpadRootView)?.update(displayContext: display)
    }
}
