import AppKit

/// Continues the launcher's desktop image through the system menu-bar region.
/// AppKit's true menu suppression also disables Dock. Keeping Dock interactive
/// requires the main window below it and only this narrow surface above menus.
/// There is no separate tint, material, captured menu, or black cover here.
@MainActor
final class MenuBarBackdropWindow: NSWindow {
    private let clippingView = NSView(frame: .zero)
    private let desktopView = NSImageView(frame: .zero)
    private let wallpaperView = NSImageView(frame: .zero)

    var transitionLayer: CALayer? { wallpaperView.layer }

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        ignoresMouseEvents = false

        clippingView.wantsLayer = true
        clippingView.layer?.masksToBounds = true
        clippingView.layer?.backgroundColor = DesktopWallpaperProvider.fallbackColor.cgColor
        clippingView.setAccessibilityHidden(true)

        for view in [desktopView, wallpaperView] {
            view.imageFrameStyle = .none
            view.imageAlignment = .alignCenter
            view.imageScaling = .scaleAxesIndependently
            view.wantsLayer = true
            view.setAccessibilityHidden(true)
            clippingView.addSubview(view)
        }
        contentView = clippingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // This surface deliberately occupies the menu region, not visibleFrame.
        frameRect
    }

    func present(on screen: NSScreen, desktopImage: NSImage?, wallpaperImage: NSImage?) {
        let screenFrame = screen.frame
        let height = max(
            NSStatusBar.system.thickness,
            screenFrame.maxY - screen.visibleFrame.maxY,
            screen.safeAreaInsets.top,
            screen.auxiliaryTopLeftArea?.height ?? 0,
            screen.auxiliaryTopRightArea?.height ?? 0
        )
        setFrame(CGRect(
            x: screenFrame.minX, y: screenFrame.maxY - height,
            width: screenFrame.width, height: height
        ), display: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clippingView.frame = CGRect(origin: .zero, size: frame.size)
        desktopView.image = desktopImage
        wallpaperView.image = wallpaperImage
        // Use the full-screen image and exactly the main window's coordinates.
        // The clip exposes only its top rows, without a second scale or blur.
        wallpaperView.frame = CGRect(
            x: 0, y: height - screenFrame.height,
            width: screenFrame.width, height: screenFrame.height
        )
        desktopView.frame = wallpaperView.frame
        CATransaction.commit()
        orderFrontRegardless()
    }

    func dismiss() { orderOut(nil) }
}
