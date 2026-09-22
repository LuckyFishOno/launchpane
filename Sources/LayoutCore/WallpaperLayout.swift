import CoreGraphics
import DisplayCore

public enum WallpaperScaling: Equatable, Sendable {
    case proportional
    case proportionalDown
    case stretch
    case center
}

/// macOS uses Fill Screen for a desktop whose clipping option is omitted.
/// An explicit Fit to Screen choice still needs its unfilled margins.
public struct WallpaperPlacementOptions: Equatable, Sendable {
    public let scaling: WallpaperScaling
    public let allowsClipping: Bool

    public init(scaling: WallpaperScaling, allowsClipping: Bool?) {
        self.scaling = scaling
        self.allowsClipping = allowsClipping ?? true
    }
}

/// Extend the menu continuation by one backing pixel past the system menu
/// boundary to keep the two window surfaces overlapped during their fade.
public enum MenuBarCoverage {
    public static func height(requiredHeights: [CGFloat], backingScaleFactor: CGFloat) -> CGFloat {
        let systemHeight = requiredHeights.filter { $0.isFinite && $0 >= 0 }.max() ?? 0
        let scale = backingScaleFactor.isFinite && backingScaleFactor > 0
            ? backingScaleFactor : 1
        return systemHeight + 1 / scale
    }
}

/// The deliberately blurred material needs far fewer pixels than app artwork.
/// Keep this budget independent of named monitor resolutions or UI backing scale.
public enum WallpaperRasterMetrics {
    public static let maximumLongEdge: CGFloat = 1280
}

public struct FrostedWallpaperRasterLayout: Equatable, Sendable {
    public let canvasBounds: CGRect
    public let imageTransform: CGAffineTransform
    public let blurScale: CGFloat

    public init?(
        nativeCanvas: CGRect,
        maximumLongEdge: CGFloat = WallpaperRasterMetrics.maximumLongEdge
    ) {
        guard !nativeCanvas.isInfinite, !nativeCanvas.isNull,
              nativeCanvas.origin.x.isFinite, nativeCanvas.origin.y.isFinite,
              nativeCanvas.width.isFinite, nativeCanvas.width > 0,
              nativeCanvas.height.isFinite, nativeCanvas.height > 0,
              maximumLongEdge.isFinite, maximumLongEdge >= 1 else { return nil }
        let reduction = min(1, maximumLongEdge / max(nativeCanvas.width, nativeCanvas.height))
        let width = max(1, (nativeCanvas.width * reduction).rounded(.down))
        let height = max(1, (nativeCanvas.height * reduction).rounded(.down))
        canvasBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let scaleX = width / nativeCanvas.width
        let scaleY = height / nativeCanvas.height
        imageTransform = CGAffineTransform(
            a: scaleX, b: 0, c: 0, d: scaleY,
            tx: -nativeCanvas.minX * scaleX, ty: -nativeCanvas.minY * scaleY
        )
        blurScale = sqrt(scaleX * scaleY)
    }
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
