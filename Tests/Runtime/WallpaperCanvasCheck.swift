// Compiles alongside the real AppKit UI sources. Creates no windows, performs
// no application discovery, and redirects any accidental persistence to /tmp.
// Native screens test actual wallpaper pixels; synthetic contexts exercise view
// geometry only because DesktopWallpaperProvider resolves a real NSScreen.
import AppCore
import AppKit
import DisplayCore
import LayoutCore
import QuartzCore

@MainActor
private final class WallpaperCanvasAssertions {
    private(set) var count = 0
    private(set) var failures = 0

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() {
            failures += 1
            print("FAIL \(message)")
        }
    }

    private func value<T>(_ object: Any, _ key: String, as: T.Type = T.self) -> T? {
        guard let raw = Mirror(reflecting: object).children.first(where: { $0.label == key })?.value else {
            return nil
        }
        let mirror = Mirror(reflecting: raw)
        if mirror.displayStyle == .optional {
            return mirror.children.first?.value as? T
        }
        return raw as? T
    }

    private func image(in layer: CALayer?) -> CGImage? {
        guard let contents = layer?.contents,
              CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage)
    }

    private func close(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.000_001 && abs(lhs.y - rhs.y) < 0.000_001
    }

    func verify(_ root: LaunchpadRootView, display: DisplayContext, label: String) {
        guard let background = root.presentationBackgroundLayer else {
            check(false, "\(label): a background layer exists")
            return
        }
        guard let host = root.subviews.first(where: { $0.layer === background }) else {
            check(false, "\(label): the background belongs to a direct host view")
            return
        }

        check(!(host is NSImageView), "\(label): wallpaper has no NSImageView raster backing")
        check(host.layerContentsRedrawPolicy == .never, "\(label): AppKit preserves supplied contents")
        check(host.frame == root.bounds, "\(label): host fills the complete root canvas")
        check(background.frame == host.bounds, "\(label): background frame equals host bounds")
        check(background.bounds.size == display.frame.size, "\(label): background uses logical display size")
        check(background.contentsScale == display.backingScaleFactor, "\(label): background follows display scale")
        check(background.contentsGravity == .resize, "\(label): precomposited pixels map edge to edge")
        check(background.masksToBounds, "\(label): pixels remain clipped to the desktop canvas")
        check(host.isAccessibilityHidden(), "\(label): wallpaper stays outside the accessibility tree")
        check(root.bounds.size == display.frame.size, "\(label): root reflects supplied display geometry")
        check(root.window == nil, "\(label): root remains unattached to a window")
        check(value(root, "hasLoadedApplications", as: Bool.self) == false,
              "\(label): creating/preparing a root does not begin discovery")
        check(value(root, "applications", as: [ApplicationRecord].self)?.isEmpty == true,
              "\(label): application catalog remains empty")
        check(value(root, "pagingDisplayLink", as: CADisplayLink.self) == nil,
              "\(label): an unattached root has no running display link")

        if let backdrop = root.desktopBackdropImage {
            guard let expected = backdrop.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let actual = image(in: background) else {
                check(false, "\(label): cached wallpaper exposes CGImage pixels")
                return
            }
            check(actual === expected, "\(label): layer shares the cached wallpaper CGImage")
        } else {
            check(image(in: background) == nil, "\(label): missing wallpaper preserves the solid fallback")
            check(background.backgroundColor != nil, "\(label): missing wallpaper has a fallback color")
        }

        // Apply the same documented centered transforms as LaunchpadWindow,
        // without creating the window or changing any presentation state.
        guard let foreground = root.layer else {
            check(false, "\(label): foreground layer exists")
            return
        }
        let foregroundCenter = CGPoint(x: foreground.bounds.midX, y: foreground.bounds.midY)
        let backgroundCenter = CGPoint(x: background.bounds.midX, y: background.bounds.midY)
        check(foreground.bounds.size == background.bounds.size,
              "\(label): foreground and wallpaper share one transform canvas")
        let foregroundAnchor = CGPoint(
            x: foreground.bounds.minX + foreground.bounds.width * foreground.anchorPoint.x,
            y: foreground.bounds.minY + foreground.bounds.height * foreground.anchorPoint.y
        )
        let backgroundAnchor = CGPoint(
            x: background.bounds.minX + background.bounds.width * background.anchorPoint.x,
            y: background.bounds.minY + background.bounds.height * background.anchorPoint.y
        )
        func apply(_ point: CGPoint, transform: CGAffineTransform, anchor: CGPoint) -> CGPoint {
            let local = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y).applying(transform)
            return CGPoint(x: local.x + anchor.x, y: local.y + anchor.y)
        }
        for scale: CGFloat in [1, 1.04, 1.085] {
            let outward = CenteredPresentationTransform.make(
                bounds: foreground.bounds, anchorPoint: foreground.anchorPoint, scale: scale
            )
            let inverse = CenteredPresentationTransform.make(
                bounds: background.bounds, anchorPoint: background.anchorPoint, scale: 1 / scale
            )
            check(close(apply(foregroundCenter, transform: outward, anchor: foregroundAnchor), foregroundCenter),
                  "\(label): foreground scale \(scale) fixes the display center")
            check(close(apply(backgroundCenter, transform: inverse, anchor: backgroundAnchor), backgroundCenter),
                  "\(label): wallpaper scale \(scale) fixes the same center")
            for point in [CGPoint.zero, backgroundCenter,
                          CGPoint(x: background.bounds.maxX, y: background.bounds.maxY)] {
                let counterScaled = apply(point, transform: inverse, anchor: backgroundAnchor)
                let final = apply(counterScaled, transform: outward, anchor: foregroundAnchor)
                check(close(final, point), "\(label): foreground/background compensation fixes \(point)")
            }
        }

        // Search/layout may run while a dismissal is being reversed. Preserve
        // the logical canvas while its background has a nonidentity transform;
        // setting CALayer.frame in this state would inflate its bounds.
        let savedTransform = background.transform
        let savedBounds = background.bounds
        let savedPosition = background.position
        let counterTransform = CATransform3DMakeAffineTransform(CenteredPresentationTransform.make(
            bounds: savedBounds, anchorPoint: background.anchorPoint, scale: 1 / 1.085
        ))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.transform = counterTransform
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        check(background.bounds == savedBounds, "\(label): relayout during reversal preserves canvas bounds")
        check(close(background.position, savedPosition), "\(label): relayout during reversal preserves canvas position")
        check(CATransform3DEqualToTransform(background.transform, counterTransform),
              "\(label): relayout during reversal preserves the in-flight transform")
        background.transform = savedTransform
        background.bounds = savedBounds
        background.position = savedPosition
        CATransaction.commit()
    }

    func run() throws {
        let isolationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchpane-wallpaper-canvas-\(UUID().uuidString)", isDirectory: true)
        let layoutURL = isolationDirectory.appendingPathComponent("layout.json")
        setenv("LAUNCHPANE_LAYOUT_PATH", layoutURL.path, 1)
        // There is deliberately no directory to read or write. A production
        // regression which starts discovery/persistence must not reach user data.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let initialWindows = application.windows.count
        let resolver = ScreenDisplayContextResolver()
        let screens = NSScreen.screens
        check(!screens.isEmpty, "at least one connected screen is available")

        for (index, screen) in screens.enumerated() {
            let native = resolver.resolve(screen)
            let root = LaunchpadRootView(frame: native.localFrameBounds, displayContext: native)
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            let label = "screen \(index) \(native.frame.size) @\(native.backingScaleFactor)x"
            verify(root, display: native, label: label)

            if let pixels = image(in: root.presentationBackgroundLayer) {
                let raster = FrostedWallpaperRasterLayout(nativeCanvas: CGRect(
                    x: 0, y: 0,
                    width: (native.frame.width * native.backingScaleFactor).rounded(),
                    height: (native.frame.height * native.backingScaleFactor).rounded()
                ))!
                check(pixels.width == Int(raster.canvasBounds.width),
                      "\(label): wallpaper follows the bounded material width")
                check(pixels.height == Int(raster.canvasBounds.height),
                      "\(label): wallpaper follows the bounded material height")
                for iteration in 0 ..< 3 {
                    root.prepareForPresentation(displayContext: native)
                    root.needsLayout = true
                    root.layoutSubtreeIfNeeded()
                    root.needsDisplay = true
                    root.displayIfNeeded()
                    check(image(in: root.presentationBackgroundLayer) === pixels,
                          "\(label): preparation/layout/redraw \(iteration) reuses exact image")
                }
            } else {
                print("NOTE \(label): current desktop image unavailable; fallback checked")
            }

            // The same physical source is used here. These cases cover logical
            // coordinates and scale changes, not synthetic WindowServer pixels.
            for scale: CGFloat in [1, 2] {
                let frame = CGRect(x: -native.frame.width * 0.7, y: native.frame.height * 0.2,
                                   width: native.frame.width * 0.73, height: native.frame.height * 1.13)
                let synthetic = DisplayContext(
                    displayID: native.displayID, frame: frame,
                    visibleFrame: frame.insetBy(dx: 12, dy: 30), backingScaleFactor: scale
                )
                root.prepareForPresentation(displayContext: synthetic)
                root.needsLayout = true
                root.layoutSubtreeIfNeeded()
                verify(root, display: synthetic, label: "synthetic geometry @\(scale)x")
            }
            root.prepareForPresentation(displayContext: native)
            verify(root, display: native, label: "\(label) restored")
        }
        check(application.windows.count == initialWindows, "no window was created")
        check(!FileManager.default.fileExists(atPath: isolationDirectory.path),
              "no application discovery or layout persistence wrote to the isolated path")
    }
}

@main
struct WallpaperCanvasCheck {
    @MainActor static func main() throws {
        let assertions = WallpaperCanvasAssertions()
        try assertions.run()
        print("WALLPAPER CANVAS: \(assertions.count) assertions, \(assertions.failures) failures")
        exit(assertions.failures == 0 ? 0 : 1)
    }
}
