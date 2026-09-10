import CoreGraphics
@testable import DisplayCore
import XCTest

final class DisplayContextTests: XCTestCase {
    func testDerivedDisplayPropertiesUseLogicalVisibleFrame() {
        let context = DisplayContext(
            displayID: 42,
            frame: CGRect(x: 1440, y: 0, width: 3440, height: 1440),
            visibleFrame: CGRect(x: 1440, y: 40, width: 3440, height: 1360),
            backingScaleFactor: 2,
            safeInsets: DisplayInsets(top: 24, leading: 8, bottom: 12, trailing: 8),
            hasNotch: true
        )

        XCTAssertEqual(context.logicalWidth, 3440)
        XCTAssertEqual(context.logicalHeight, 1360)
        XCTAssertTrue(context.isRetina)
        XCTAssertTrue(context.isUltrawide)
        XCTAssertTrue(context.hasNotch)
        XCTAssertEqual(context.localFrameBounds, CGRect(x: 0, y: 0, width: 3440, height: 1440))
        XCTAssertEqual(context.localVisibleBounds, CGRect(x: 0, y: 40, width: 3440, height: 1360))
        XCTAssertEqual(context.safeBounds, CGRect(x: 8, y: 40, width: 3424, height: 1360))
    }

    func testScaleFactorCannotFallBelowOne() {
        let context = DisplayContext(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            backingScaleFactor: 0
        )

        XCTAssertEqual(context.backingScaleFactor, 1)
    }

    func testVisibleFrameOffsetsAreRelativeToTheirDisplay() {
        let context = DisplayContext(
            displayID: 2,
            frame: CGRect(x: -1920, y: 200, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1870, y: 224, width: 1870, height: 1016),
            backingScaleFactor: 1,
            safeInsets: DisplayInsets(top: 30, leading: 12)
        )

        XCTAssertEqual(context.localVisibleBounds, CGRect(x: 50, y: 24, width: 1870, height: 1016))
        XCTAssertEqual(context.safeBounds, CGRect(x: 50, y: 24, width: 1870, height: 1016))
    }
}
