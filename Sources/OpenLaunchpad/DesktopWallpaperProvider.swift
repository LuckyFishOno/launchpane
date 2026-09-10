import AppKit
import CoreImage
import DisplayCore

@MainActor
enum DesktopWallpaperProvider {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    private enum Metrics {
        static let blurRadius: CGFloat = 52
    }

    static func image(for displayID: CGDirectDisplayID) -> NSImage? {
        guard
            let screen = DisplaySelector.screen(with: displayID) ?? NSScreen.main ?? NSScreen.screens.first,
            let imageURL = NSWorkspace.shared.desktopImageURL(for: screen),
            let source = sourceImage(at: imageURL)
        else { return nil }

        let sourceExtent = source.extent.integral
        guard
            !sourceExtent.isEmpty,
            sourceExtent.origin.x.isFinite,
            sourceExtent.origin.y.isFinite,
            sourceExtent.width.isFinite,
            sourceExtent.height.isFinite,
            sourceExtent.width > 0,
            sourceExtent.height > 0
        else { return nil }

        let output = source
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: Metrics.blurRadius]
            )
            .cropped(to: sourceExtent)

        guard let blurred = context.createCGImage(output, from: sourceExtent) else {
            return fallbackImage(from: source)
        }

        // Use the decoded pixel dimensions instead of the source file's DPI metadata.
        // NSImageView can then aspect-fit the complete wallpaper without accidentally
        // treating a high-DPI image as though it had a different aspect ratio.
        return NSImage(
            cgImage: blurred,
            size: NSSize(width: blurred.width, height: blurred.height)
        )
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

    private static func fallbackImage(from source: CIImage) -> NSImage? {
        let sourceExtent = source.extent.integral
        guard let cgImage = context.createCGImage(source, from: sourceExtent) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
