import AppKit

/// Continues the launcher's desktop image through the system menu-bar region.
/// AppKit's true menu suppression also disables Dock. Keeping Dock interactive
/// requires the main window below it and only this narrow surface above menus.
/// There is no separate tint, material, captured menu, or black cover here.
@MainActor
final class MenuBarBackdropWindow: NSWindow {
    private let clippingView = NSView(frame: .zero)
    private let desktopLayer = CALayer()
    private let wallpaperLayer = CALayer()

    var transitionLayer: CALayer? { wallpaperLayer }

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

        for layer in [desktopLayer, wallpaperLayer] {
            layer.contentsGravity = .resize
            clippingView.layer?.addSublayer(layer)
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
        let height = DesktopWallpaperProvider.menuBarHeight(on: screen)
        setFrame(CGRect(
            x: screenFrame.minX, y: screenFrame.maxY - height,
            width: screenFrame.width, height: height
        ), display: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clippingView.frame = CGRect(origin: .zero, size: frame.size)
        desktopLayer.contents = desktopImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        wallpaperLayer.contents = wallpaperImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let desktopSize = desktopImage?.size ?? frame.size
        desktopLayer.frame = CGRect(
            x: 0, y: height - desktopSize.height, width: desktopSize.width, height: desktopSize.height
        )
        // Share the entire small frosted raster using the main window's exact
        // full-display coordinates. Cropping the low-resolution bitmap first
        // changes interpolation at the seam. A direct CALayer contents image
        // does not allocate a second full-screen image-view backing store.
        wallpaperLayer.frame = CGRect(
            x: 0, y: height - screenFrame.height, width: screenFrame.width, height: screenFrame.height
        )
        desktopLayer.contentsScale = screen.backingScaleFactor
        wallpaperLayer.contentsScale = screen.backingScaleFactor
        CATransaction.commit()
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)

        // Ordering a window out does not guarantee Core Animation immediately
        // drops the layer contents. Release the menu continuation textures while
        // hidden; DesktopWallpaperProvider can supply them again on next show.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        desktopLayer.contents = nil
        wallpaperLayer.contents = nil
        CATransaction.commit()
    }
}
