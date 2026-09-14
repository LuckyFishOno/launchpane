// Standalone deterministic image checks; no windows or user desktop changes.
import AppKit
import CoreImage
import DisplayCore
import LayoutCore

@main
@MainActor
struct WallpaperRasterCheck {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        // Unequal rows and columns expose inverted crops, changed wallpaper
        // placement, and half-pixel interpolation at the menu-window seam.
        let source = CIImage(cgImage: makePattern(width: 97, height: 71))
        let fillColor = NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.37, alpha: 1)
        let context = CIContext(options: [.cacheIntermediates: false])
        for scale: CGFloat in [1, 1.25, 2, 3] {
            let display = DisplayContext(
                displayID: 1,
                frame: CGRect(x: -120, y: 32, width: 103, height: 79),
                visibleFrame: CGRect(x: -120, y: 32, width: 103, height: 72),
                backingScaleFactor: scale
            )
            for scaling: WallpaperScaling in [.proportional, .proportionalDown, .stretch, .center] {
                for clips in [false, true] {
                    let layout = WallpaperLayout(
                        sourceExtent: source.extent, display: display,
                        scaling: scaling, allowsClipping: clips
                    )!
                    let fill = CIImage(color: CIColor(
                        red: fillColor.redComponent, green: fillColor.greenComponent,
                        blue: fillColor.blueComponent, alpha: 1
                    ))
                        .cropped(to: layout.canvasBounds)
                    let desktop = source.transformed(by: layout.imageTransform)
                        .composited(over: fill).cropped(to: layout.canvasBounds)
                    let oldDesktop = context.createCGImage(desktop, from: layout.canvasBounds)!
                    let images = DesktopWallpaperProvider.renderImages(
                        source: source, display: display, scaling: scaling,
                        allowsClipping: clips, fillColor: fillColor, menuBarHeight: 7.25
                    )!
                    let underlay = images.desktop.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                    let frosted = images.frosted.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                    let geometry = DesktopWallpaperProvider.MenuBarRasterGeometry(
                        displaySize: display.frame.size, canvasSize: layout.canvasBounds.size, height: 7.25
                    )
                    let originalCrop = oldDesktop.cropping(to: geometry.topRows)!
                    if underlay.width != oldDesktop.width {
                        print("Unexpected raster dimensions", scale, scaling, clips,
                              underlay.width, underlay.height, oldDesktop.width, oldDesktop.height,
                              images.desktop.representations.map { ($0.pixelsWide, $0.pixelsHigh) })
                    }
                    check(underlay.width == oldDesktop.width, "Plain underlay preserves full native width")
                    check(underlay.height == Int(geometry.topRows.height), "Plain underlay stores only menu rows")
                    check(underlay.height < oldDesktop.height / 4, "Plain underlay does not retain a full canvas")
                    check(pixels(underlay) == pixels(originalCrop), "Plain underlay matches original desktop top rows")
                    check(images.desktop.size == geometry.logicalSize, "Pixel rounding preserves original point scale")
                    check(frosted.width == oldDesktop.width && frosted.height == oldDesktop.height,
                          "Frosted wallpaper retains complete native resolution")
                    check(images.frosted.size == display.frame.size, "Material covers the original logical canvas")
                    check(images.frosted.representations.count == 1, "No extra display-scale raster is generated")

                    // The material remains the existing full-canvas filter chain.
                    let oldFrosted = desktop.clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 26 * scale])
                        .cropped(to: layout.canvasBounds)
                        .applyingFilter("CILinearToSRGBToneCurve")
                        .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.8])
                        .applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
                            "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: 0.5, w: 0),
                            "inputBiasVector": CIVector(x: 0.12, y: 0.12, z: 0.12, w: 0),
                        ])
                        .applyingFilter("CISRGBToneCurveToLinear")
                    check(pixels(frosted) == pixels(context.createCGImage(oldFrosted, from: layout.canvasBounds)!),
                          "Eager material raster is pixel-identical to the previous rendering path")
                }
            }
        }
        for size in [CGSize(width: 3840, height: 2160), CGSize(width: 2160, height: 3840)] {
            let display = DisplayContext(
                displayID: 1, frame: CGRect(origin: .zero, size: size),
                visibleFrame: CGRect(origin: .zero, size: size), backingScaleFactor: 1
            )
            let images = DesktopWallpaperProvider.renderImages(
                source: source, display: display, scaling: .stretch,
                allowsClipping: true, fillColor: fillColor, menuBarHeight: 24
            )!
            let frosted = images.frosted.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let underlay = images.desktop.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            check(max(frosted.width, frosted.height) == 1280, "Large material has a bounded long edge")
            check(frosted.bytesPerRow * frosted.height < 4 * 1024 * 1024, "4K material stays below 4 MiB")
            check(images.frosted.size == size, "Low-resolution material still fills the original display")
            check(underlay.width == Int(size.width) && underlay.height == 24,
                  "Plain menu fade underlay retains native resolution")
            check((images.frosted.cgImage(forProposedRect: nil, context: nil, hints: nil)) === frosted,
                  "Large logical image does not get expanded by NSImage lookup")
        }
        print("WALLPAPER RASTER: \(checks) assertions passed")
    }

    private static func makePattern(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                bytes[offset] = UInt8((row * 13 + column * 7) % 256)
                bytes[offset + 1] = UInt8((row * 3 + column * 11) % 256)
                bytes[offset + 2] = UInt8((row * 17 + column * 5) % 256)
            }
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
