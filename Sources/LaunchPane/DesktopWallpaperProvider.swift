import AppKit
import CoreImage
import DisplayCore
import LayoutCore

@MainActor
enum DesktopWallpaperProvider {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static var cachedWallpapers: [CGDirectDisplayID: CachedWallpaper] = [:]
    static let fallbackColor = NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.37, alpha: 1)

    struct Images {
        // Only the menu-bar fade needs the unmodified desktop. Keep that narrow
        // strip, rather than a second native-resolution display-sized raster.
        let desktop: NSImage
        let frosted: NSImage
    }

    struct MenuBarRasterGeometry {
        let topRows: CGRect
        let coreImageBounds: CGRect
        let logicalSize: CGSize

        init(displaySize: CGSize, canvasSize: CGSize, height: CGFloat) {
            // Round outwards, then retain the original pixel-to-point mapping.
            // A fractional last row is clipped by the menu window, not scaled.
            let pixelHeight = min(canvasSize.height, (height * canvasSize.height / displaySize.height).rounded(.up))
            topRows = CGRect(x: 0, y: 0, width: canvasSize.width, height: pixelHeight)
            coreImageBounds = CGRect(
                x: 0, y: canvasSize.height - pixelHeight, width: canvasSize.width, height: pixelHeight
            )
            logicalSize = CGSize(
                width: displaySize.width, height: pixelHeight * displaySize.height / canvasSize.height
            )
        }
    }

    private struct CacheKey: Equatable {
        let imageURL: URL
        let modificationDate: Date?
        let fileSize: Int?
        let displaySize: CGSize
        let backingScale: CGFloat
        let menuBarHeight: CGFloat
        let scalingValue: UInt
        let allowsClipping: Bool
        let fillComponents: [CGFloat]
    }

    private struct CachedWallpaper {
        let key: CacheKey
        let images: Images
    }

    private enum Metrics {
        // Screen-space points keep the haze consistent across wallpaper file
        // resolutions and mixed-scale displays (52 backing pixels on Retina).
        static let blurRadius: CGFloat = 26
        static let saturation: CGFloat = 1.8
        static let contrast: CGFloat = 0.5
        static let shadowLift: CGFloat = 0.12
    }

    static func image(for displayID: CGDirectDisplayID) -> NSImage? {
        images(for: displayID)?.frosted
    }

    static func images(for displayID: CGDirectDisplayID) -> Images? {
        guard
            let screen = DisplaySelector.screen(with: displayID) ?? NSScreen.main ?? NSScreen.screens.first,
            let imageURL = NSWorkspace.shared.desktopImageURL(for: screen)
        else { return nil }

        let display = ScreenDisplayContextResolver().resolve(screen)
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scalingValue = (options[.imageScaling] as? NSNumber)?.uintValue
            ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
        let scaling = NSImageScaling(rawValue: scalingValue) ?? .scaleProportionallyUpOrDown
        let placement = WallpaperPlacementOptions(
            scaling: wallpaperScaling(for: scaling),
            allowsClipping: (options[.allowClipping] as? NSNumber)?.boolValue
        )
        let fillColor = (options[.fillColor] as? NSColor)?.usingColorSpace(.deviceRGB)
            ?? fallbackColor
        let metadata = try? imageURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let menuBarHeight = menuBarHeight(on: screen)
        let key = CacheKey(
            imageURL: imageURL,
            modificationDate: metadata?.contentModificationDate,
            fileSize: metadata?.fileSize,
            displaySize: display.frame.size,
            backingScale: display.backingScaleFactor,
            menuBarHeight: menuBarHeight,
            scalingValue: scalingValue,
            allowsClipping: placement.allowsClipping,
            fillComponents: [fillColor.redComponent, fillColor.greenComponent, fillColor.blueComponent]
        )

        // Keep only connected displays and replace each entry when its desktop
        // changes. Opening again reuses the raster rather than decoding/blurring.
        let connectedDisplayIDs = Set(NSScreen.screens.map(ScreenDisplayContextResolver.displayID(for:)))
        cachedWallpapers = cachedWallpapers.filter { connectedDisplayIDs.contains($0.key) }
        if let cached = cachedWallpapers[display.displayID], cached.key == key {
            return cached.images
        }

        // Drain the source decode and filter graph before clearing GPU scratch
        // resources. Cache hits need neither a render nor a context cache purge.
        defer { context.clearCaches() }
        let result = autoreleasepool { () -> Images? in
            guard let source = sourceImage(at: imageURL) else { return nil }
            return renderImages(
                source: source, display: display, scaling: placement.scaling,
                allowsClipping: placement.allowsClipping, fillColor: fillColor, menuBarHeight: menuBarHeight
            )
        }
        guard let result else { return nil }
        cachedWallpapers[display.displayID] = CachedWallpaper(key: key, images: result)
        return result
    }

    static func menuBarHeight(on screen: NSScreen) -> CGFloat {
        MenuBarCoverage.height(requiredHeights: [
            NSStatusBar.system.thickness,
            screen.frame.maxY - screen.visibleFrame.maxY,
            screen.safeAreaInsets.top,
            screen.auxiliaryTopLeftArea?.height ?? 0,
            screen.auxiliaryTopRightArea?.height ?? 0
        ], backingScaleFactor: screen.backingScaleFactor)
    }

    static func renderImages(
        source: CIImage, display: DisplayContext, scaling: WallpaperScaling,
        allowsClipping: Bool, fillColor: NSColor, menuBarHeight: CGFloat
    ) -> Images? {
        guard let layout = WallpaperLayout(
            sourceExtent: source.extent, display: display,
            scaling: scaling, allowsClipping: allowsClipping
        ), let frostedLayout = FrostedWallpaperRasterLayout(nativeCanvas: layout.canvasBounds)
        else { return nil }

        let fill = CIImage(color: CIColor(
            red: fillColor.redComponent,
            green: fillColor.greenComponent,
            blue: fillColor.blueComponent,
            alpha: 1
        ))
            .cropped(to: layout.canvasBounds)

        // First reproduce the desktop's placement on the complete display.
        // Applying blur to the source file and then aspect-fitting it adds
        // letterboxing that the user's desktop never had.
        let desktop = source.transformed(by: layout.imageTransform)
            .composited(over: fill)
            .cropped(to: layout.canvasBounds)

        let blurred = desktop
            // Reduce only the intentionally frosted material. Placement is
            // resolved in native pixels first, so fill/fit/center do not change.
            .transformed(by: frostedLayout.imageTransform)
            .cropped(to: frostedLayout.canvasBounds)
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey:
                    Metrics.blurRadius * display.backingScaleFactor * frostedLayout.blurScale]
            )
            .cropped(to: frostedLayout.canvasBounds)

        // Make the material part of this single image. Independent live visual
        // effect views in different windows sample different backdrops and can
        // produce a visible seam across the menu-bar boundary.
        // Tone compression is in perceptual sRGB: retain wallpaper color while
        // lifting dark detail and dimming highlights behind the white labels.
        let output = blurred
            .applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: Metrics.saturation])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: Metrics.contrast, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: Metrics.contrast, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: Metrics.contrast, w: 0),
                "inputBiasVector": CIVector(
                    x: Metrics.shadowLift, y: Metrics.shadowLift, z: Metrics.shadowLift, w: 0
                ),
            ])
            .applyingFilter("CISRGBToneCurveToLinear")

        let menuGeometry = MenuBarRasterGeometry(
            displaySize: display.frame.size, canvasSize: layout.canvasBounds.size, height: menuBarHeight
        )
        // These match createCGImage's default sRGB / 8-bit output. Eager output
        // retains final pixels without keeping the source/filter graph alive.
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        guard
            let frostedImage = context.createCGImage(
                output, from: frostedLayout.canvasBounds, format: .RGBA8, colorSpace: colorSpace, deferred: false
            ),
            let desktopImage = context.createCGImage(
                desktop, from: menuGeometry.coreImageBounds, format: .RGBA8, colorSpace: colorSpace, deferred: false
            )
        else { return nil }

        // The returned image already has the display's aspect ratio. The view
        // should map this canvas edge-to-edge without fitting the source again.
        return Images(
            desktop: bitmapImage(desktopImage, size: menuGeometry.logicalSize),
            frosted: bitmapImage(frostedImage, size: display.frame.size)
        )
    }

    private static func bitmapImage(_ raster: CGImage, size: CGSize) -> NSImage {
        // An explicit bitmap representation preserves native pixels even when
        // the requested display scale differs from the current drawing context.
        let representation = NSBitmapImageRep(cgImage: raster)
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    private static func sourceImage(at url: URL) -> CIImage? {
        if let image = CIImage(
            contentsOf: url,
            options: [.applyOrientationProperty: true]
        ) {
            return image
        }

        guard
            let image = NSImage(contentsOf: url),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        return CIImage(cgImage: cgImage)
    }

    private static func wallpaperScaling(for scaling: NSImageScaling) -> WallpaperScaling {
        switch scaling {
        case .scaleProportionallyDown: .proportionalDown
        case .scaleAxesIndependently: .stretch
        case .scaleNone: .center
        case .scaleProportionallyUpOrDown: .proportional
        @unknown default: .proportional
        }
    }
}
