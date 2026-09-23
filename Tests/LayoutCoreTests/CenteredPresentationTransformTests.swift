import CoreGraphics
import LayoutCore
import XCTest

final class CenteredPresentationTransformTests: XCTestCase {
    func testCenterStaysFixedAndAllFourSidesDisperseSymmetrically() {
        for size in [CGSize(width: 1710, height: 1112), CGSize(width: 1920, height: 1080)] {
            for anchor in [CGPoint.zero, CGPoint(x: 0, y: 1), CGPoint(x: 0.5, y: 0.5)] {
                let bounds = CGRect(origin: CGPoint(x: 17, y: 23), size: size)
                let origin = CGPoint(x: bounds.minX + size.width * anchor.x,
                                     y: bounds.minY + size.height * anchor.y)
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                for scale: CGFloat in [1, 1.02, 1.085] {
                    let transform = CenteredPresentationTransform.make(
                        bounds: bounds, anchorPoint: anchor, scale: scale
                    )
                    for offset in [CGPoint.zero, CGPoint(x: -300, y: 0), CGPoint(x: 300, y: 0),
                                   CGPoint(x: 0, y: -200), CGPoint(x: 0, y: 200)] {
                        let local = CGPoint(x: center.x + offset.x - origin.x,
                                            y: center.y + offset.y - origin.y)
                        let result = local.applying(transform)
                        XCTAssertEqual(result.x + origin.x, center.x + offset.x * scale, accuracy: 0.000001)
                        XCTAssertEqual(result.y + origin.y, center.y + offset.y * scale, accuracy: 0.000001)
                    }
                }
            }
        }
    }
}
