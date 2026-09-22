import CoreGraphics
import DisplayCore
@testable import LayoutCore
import XCTest

final class WallpaperLayoutTests: XCTestCase {
    func testMissingDesktopClippingOptionUsesFillWhileExplicitFitIsPreserved() throws {
        let fill = WallpaperPlacementOptions(scaling: .proportional, allowsClipping: nil)
        let fit = WallpaperPlacementOptions(scaling: .proportional, allowsClipping: false)
        let explicitFill = WallpaperPlacementOptions(scaling: .proportional, allowsClipping: true)

        XCTAssertTrue(fill.allowsClipping)
        XCTAssertFalse(fit.allowsClipping)
        XCTAssertTrue(explicitFill.allowsClipping)

        let fillLayout = try XCTUnwrap(WallpaperLayout(
            sourceExtent: sourceExtent, display: display,
            scaling: fill.scaling, allowsClipping: fill.allowsClipping
        ))
        let fitLayout = try XCTUnwrap(WallpaperLayout(
            sourceExtent: sourceExtent, display: display,
            scaling: fit.scaling, allowsClipping: fit.allowsClipping
        ))
        XCTAssertTrue(fillLayout.imageFrame.contains(fillLayout.canvasBounds))
        XCTAssertFalse(fitLayout.imageFrame.contains(fitLayout.canvasBounds))
    }

    func testFrostedRasterIsBoundedIndependentlyOfDisplayResolution() throws {
        for size in [CGSize(width: 3840, height: 2160), CGSize(width: 15360, height: 8640)] {
            let raster = try XCTUnwrap(FrostedWallpaperRasterLayout(nativeCanvas: CGRect(origin: .zero, size: size)))
            XCTAssertEqual(raster.canvasBounds.size, CGSize(width: 1280, height: 720))
            XCTAssertLessThanOrEqual(raster.canvasBounds.width * raster.canvasBounds.height * 4, 4 * 1024 * 1024)
            XCTAssertEqual(size.width * raster.imageTransform.a, 1280, accuracy: 0.001)
            XCTAssertEqual(size.height * raster.imageTransform.d, 720, accuracy: 0.001)
        }
    }

    func testFrostedRasterPreservesPortraitAndDoesNotUpscaleSmallDisplays() throws {
        let portrait = try XCTUnwrap(FrostedWallpaperRasterLayout(
            nativeCanvas: CGRect(x: 0, y: 0, width: 2160, height: 3840)
        ))
        XCTAssertEqual(portrait.canvasBounds.size, CGSize(width: 720, height: 1280))
        let small = try XCTUnwrap(FrostedWallpaperRasterLayout(
            nativeCanvas: CGRect(x: 0, y: 0, width: 640, height: 480)
        ))
        XCTAssertEqual(small.canvasBounds.size, CGSize(width: 640, height: 480))
        XCTAssertEqual(small.imageTransform, .identity)
        XCTAssertEqual(small.blurScale, 1)
    }

    func testFrostedRasterMapsTheCompleteCanvasAndScalesBlur() throws {
        let native = CGRect(x: -90, y: 25, width: 3420, height: 2224)
        let raster = try XCTUnwrap(FrostedWallpaperRasterLayout(nativeCanvas: native))
        XCTAssertEqual(raster.canvasBounds.width, 1280)
        XCTAssertEqual(raster.canvasBounds.height, 832)
        let transformed = native.applying(raster.imageTransform)
        XCTAssertEqual(transformed.minX, 0, accuracy: 0.001)
        XCTAssertEqual(transformed.minY, 0, accuracy: 0.001)
        XCTAssertEqual(transformed.width, raster.canvasBounds.width, accuracy: 0.001)
        XCTAssertEqual(transformed.height, raster.canvasBounds.height, accuracy: 0.001)
        XCTAssertEqual(raster.blurScale, sqrt(raster.imageTransform.a * raster.imageTransform.d), accuracy: 0.000_001)
    }

    func testFrostedRasterRejectsInvalidGeometryAndBudgets() {
        for canvas in [CGRect.zero, .infinite, .null] {
            XCTAssertNil(FrostedWallpaperRasterLayout(nativeCanvas: canvas))
        }
        let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
        for limit: CGFloat in [0, -1, .infinity, .nan] {
            XCTAssertNil(FrostedWallpaperRasterLayout(nativeCanvas: canvas, maximumLongEdge: limit))
        }
    }

    func testDesktopFillCoversEntireNotchedDisplayWithoutLetterboxing() throws {
        let layout = try makeLayout(scaling: .proportional, allowsClipping: true)

        XCTAssertEqual(layout.canvasBounds, CGRect(x: 0, y: 0, width: 3420, height: 2224))
        XCTAssertEqual(layout.imageFrame.height, 2224, accuracy: 0.001)
        XCTAssertEqual(layout.imageFrame.width, 3953.7777778, accuracy: 0.001)
        XCTAssertEqual(layout.imageFrame.minY, 0, accuracy: 0.001)
        XCTAssertTrue(layout.imageFrame.contains(layout.canvasBounds))
        XCTAssertEqual(layout.imageFrame.midX, layout.canvasBounds.midX, accuracy: 0.001)
    }

    func testDesktopFitPreservesIntentionalSpaceForDesktopFillColor() throws {
        let layout = try makeLayout(scaling: .proportional, allowsClipping: false)

        XCTAssertEqual(layout.imageFrame.width, 3420, accuracy: 0.001)
        XCTAssertEqual(layout.imageFrame.height, 1923.75, accuracy: 0.001)
        XCTAssertEqual(layout.imageFrame.minY, 150.125, accuracy: 0.001)
        XCTAssertTrue(layout.canvasBounds.contains(layout.imageFrame))
    }

    func testDisplayOriginAndReservedSystemAreasDoNotChangeWallpaperPlacement() throws {
        let primary = try makeLayout(scaling: .proportional, allowsClipping: true)
        let external = try XCTUnwrap(WallpaperLayout(
            sourceExtent: sourceExtent,
            display: DisplayContext(
                displayID: 2,
                frame: CGRect(x: -1710, y: 240, width: 1710, height: 1112),
                visibleFrame: CGRect(x: -1660, y: 290, width: 1660, height: 1023),
                backingScaleFactor: 2,
                safeInsets: DisplayInsets(top: 39, leading: 50, bottom: 50),
                hasNotch: true
            ),
            scaling: .proportional,
            allowsClipping: true
        ))

        XCTAssertEqual(primary, external)
    }

    func testStretchUsesTheFullCanvasRegardlessOfClippingOption() throws {
        let layout = try makeLayout(scaling: .stretch, allowsClipping: false)
        XCTAssertEqual(layout.imageFrame, layout.canvasBounds)
        XCTAssertEqual(sourceExtent.applying(layout.imageTransform), layout.canvasBounds)
    }

    func testCenterKeepsNativePixelsAndCentersOnTheFullDisplay() throws {
        let layout = try makeLayout(scaling: .center, allowsClipping: true)
        XCTAssertEqual(layout.imageFrame.size, sourceExtent.size)
        XCTAssertEqual(layout.imageFrame.origin, CGPoint(x: -210, y: 32))
    }

    func testTransformNormalizesNonzeroSourceOriginOnOneTimesDisplay() throws {
        let extent = CGRect(x: -120, y: 80, width: 400, height: 300)
        let layout = try XCTUnwrap(WallpaperLayout(
            sourceExtent: extent,
            display: DisplayContext(
                displayID: 3,
                frame: CGRect(x: 1920, y: -1080, width: 800, height: 600),
                visibleFrame: CGRect(x: 1920, y: -1080, width: 800, height: 560),
                backingScaleFactor: 1
            ),
            scaling: .proportional,
            allowsClipping: true
        ))

        XCTAssertEqual(layout.canvasBounds, CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(extent.applying(layout.imageTransform), layout.canvasBounds)
    }

    func testProportionalDownDoesNotEnlargeSmallImages() throws {
        let layout = try XCTUnwrap(WallpaperLayout(
            sourceExtent: CGRect(x: 0, y: 0, width: 400, height: 300),
            display: display,
            scaling: .proportionalDown,
            allowsClipping: false
        ))
        XCTAssertEqual(layout.imageFrame.size, CGSize(width: 400, height: 300))
        XCTAssertEqual(layout.imageFrame.midX, layout.canvasBounds.midX)
        XCTAssertEqual(layout.imageFrame.midY, layout.canvasBounds.midY)
    }

    func testInvalidSourceCannotProduceAnInfiniteTransform() {
        for source in [CGRect.zero, .infinite, CGRect(x: 0, y: 0, width: 100, height: 0)] {
            XCTAssertNil(WallpaperLayout(
                sourceExtent: source,
                display: display,
                scaling: .proportional,
                allowsClipping: true
            ))
        }
    }

    private let sourceExtent = CGRect(x: 0, y: 0, width: 3840, height: 2160)
    private let display = DisplayContext(
        displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073),
        backingScaleFactor: 2,
        safeInsets: DisplayInsets(top: 39),
        hasNotch: true
    )

    private func makeLayout(
        scaling: WallpaperScaling,
        allowsClipping: Bool
    ) throws -> WallpaperLayout {
        try XCTUnwrap(WallpaperLayout(
            sourceExtent: sourceExtent,
            display: display,
            scaling: scaling,
            allowsClipping: allowsClipping
        ))
    }
}
