import CoreGraphics
import DisplayCore

public enum WallpaperScaling: Equatable, Sendable {
    case proportional
    case proportionalDown
    case stretch
    case center
}

/// Placement of the desktop image on the complete display, in backing pixels.
/// Menu-bar, Dock and notch reservations affect controls, not wallpaper framing.
public struct WallpaperLayout: Equatable, Sendable {
    public let canvasBounds: CGRect
    public let imageFrame: CGRect
    public let imageTransform: CGAffineTransform

    public init?(
        sourceExtent: CGRect,
        display: DisplayContext,
        scaling: WallpaperScaling,
        allowsClipping: Bool
    ) {
        let canvasSize = CGSize(
            width: (display.frame.width * display.backingScaleFactor).rounded(),
            height: (display.frame.height * display.backingScaleFactor).rounded()
        )
        guard
            !sourceExtent.isInfinite, !sourceExtent.isNull,
            sourceExtent.origin.x.isFinite,
            sourceExtent.origin.y.isFinite,
            sourceExtent.width.isFinite, sourceExtent.width > 0,
            sourceExtent.height.isFinite, sourceExtent.height > 0,
            canvasSize.width.isFinite, canvasSize.width > 0,
            canvasSize.height.isFinite, canvasSize.height > 0
        else { return nil }

        canvasBounds = CGRect(origin: .zero, size: canvasSize)
        let widthScale = canvasSize.width / sourceExtent.width
        let heightScale = canvasSize.height / sourceExtent.height
        let imageSize: CGSize

        switch scaling {
        case .proportional, .proportionalDown:
            var scale = allowsClipping
                ? max(widthScale, heightScale)
                : min(widthScale, heightScale)
            if scaling == .proportionalDown {
                scale = min(1, scale)
            }
            imageSize = CGSize(
                width: sourceExtent.width * scale,
                height: sourceExtent.height * scale
            )
        case .stretch:
            imageSize = canvasSize
        case .center:
            imageSize = sourceExtent.size
        }

        imageFrame = CGRect(
            x: (canvasSize.width - imageSize.width) / 2,
            y: (canvasSize.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        let scaleX = imageSize.width / sourceExtent.width
        let scaleY = imageSize.height / sourceExtent.height
        imageTransform = CGAffineTransform(
            a: scaleX, b: 0,
            c: 0, d: scaleY,
            tx: imageFrame.minX - sourceExtent.minX * scaleX,
            ty: imageFrame.minY - sourceExtent.minY * scaleY
        )
    }
}
