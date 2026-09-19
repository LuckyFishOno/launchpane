import CoreGraphics
@testable import LayoutCore
import XCTest

final class FolderMergeGeometryTests: XCTestCase {
    private typealias Target = FolderMergeGeometry.Target<String>
    private let icon = CGRect(x: 100, y: 200, width: 100, height: 100)

    func testAllEightApproachDirectionsHaveTheSameNormalizedDistanceAndAcquisition() throws {
        for direction in directions {
            let inside = translatedIcon(distance: 0.43, direction: direction)
            let outside = translatedIcon(distance: 0.45, direction: direction)

            XCTAssertEqual(
                try XCTUnwrap(FolderMergeGeometry.normalizedDistance(draggedIcon: inside, targetIcon: icon)),
                0.43,
                accuracy: 0.000_000_001
            )
            XCTAssertEqual(target(for: inside), "target", "Direction: \(direction)")
            XCTAssertNil(target(for: outside), "Direction: \(direction)")
        }
    }

    func testIconPerimeterAndDiagonalCornersDoNotAcquireFolderIntent() {
        for direction in directions {
            XCTAssertNil(target(for: translatedIcon(distance: 0.55, direction: direction)))
        }
        // Both per-axis distances are below the radius, but the diagonal is not.
        XCTAssertNil(target(for: icon.offsetBy(dx: 34, dy: 34)))
    }

    func testRetentionHasDirectionalHysteresisWithoutAcquiringANewTarget() {
        for direction in directions {
            let betweenRadii = translatedIcon(distance: 0.50, direction: direction)
            XCTAssertNil(target(for: betweenRadii))
            XCTAssertEqual(target(for: betweenRadii, retaining: "target"), "target")
            XCTAssertNil(target(for: translatedIcon(distance: 0.55, direction: direction), retaining: "target"))
        }
    }

    func testApproachZoneCanHoldReorderBeforeMergeAcquires() {
        let nearButNotMerged = translatedIcon(distance: 0.50, direction: CGVector(dx: 1, dy: 0))

        XCTAssertNil(target(for: nearButNotMerged))
        XCTAssertTrue(FolderMergeGeometry.isApproachingTarget(
            draggedIcon: nearButNotMerged,
            targets: [Target(id: "target", iconFrame: icon)]
        ))
        XCTAssertFalse(FolderMergeGeometry.isApproachingTarget(
            draggedIcon: translatedIcon(distance: 0.80, direction: CGVector(dx: 1, dy: 0)),
            targets: [Target(id: "target", iconFrame: icon)]
        ))
    }

    func testClosestAcquisitionWinsRegardlessOfIterationOrder() {
        let farther = Target(id: "farther", iconFrame: icon.offsetBy(dx: 30, dy: 0))
        let nearer = Target(id: "nearer", iconFrame: icon.offsetBy(dx: 5, dy: 0))

        for targets in [[farther, nearer], [nearer, farther]] {
            XCTAssertEqual(FolderMergeGeometry.target(draggedIcon: icon, targets: targets, retaining: nil), "nearer")
        }
    }

    func testStrongAcquisitionCanReplaceAWeakRetainedTarget() {
        let old = Target(id: "old", iconFrame: icon.offsetBy(dx: 42, dy: 0))
        let new = Target(id: "new", iconFrame: icon.offsetBy(dx: 4, dy: 0))

        XCTAssertEqual(
            FolderMergeGeometry.target(draggedIcon: icon, targets: [old, new], retaining: "old"),
            "new"
        )
    }

    func testRetentionCannotResurrectAnAbsentOrMovedTarget() {
        XCTAssertNil(FolderMergeGeometry.target(draggedIcon: icon, targets: [Target](), retaining: "gone"))
        XCTAssertNil(FolderMergeGeometry.target(
            draggedIcon: icon,
            targets: [Target(id: "moved", iconFrame: icon.offsetBy(dx: 200, dy: 0))],
            retaining: "moved"
        ))
    }

    func testOverlapUsesSmallerIconAreaAndRejectsThinIncidentalOverlap() {
        let smallCentered = CGRect(x: icon.midX - 15, y: icon.midY - 15, width: 30, height: 30)
        XCTAssertEqual(target(for: smallCentered), "target")

        let wideSliver = CGRect(x: icon.midX - 250, y: icon.midY - 5, width: 500, height: 10)
        XCTAssertNil(target(for: wideSliver))
        XCTAssertNil(target(for: wideSliver, retaining: "target"))
    }

    func testNormalizedGeometrySupportsNonSquareIconsAndTranslatedScaledDisplays() throws {
        let nonSquare = CGRect(x: -420, y: 700, width: 80, height: 120)

        for scale in [CGFloat(0.5), 1, 2, 3] {
            for direction in directions {
                let baseDrag = nonSquare.offsetBy(
                    dx: 0.43 * direction.dx * nonSquare.width,
                    dy: 0.43 * direction.dy * nonSquare.height
                )
                let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: 713, ty: -251)
                let target = nonSquare.applying(transform)
                let dragged = baseDrag.applying(transform)

                XCTAssertEqual(
                    try XCTUnwrap(FolderMergeGeometry.normalizedDistance(draggedIcon: dragged, targetIcon: target)),
                    0.43,
                    accuracy: 0.000_000_001
                )
                XCTAssertEqual(FolderMergeGeometry.target(
                    draggedIcon: dragged,
                    targets: [Target(id: "target", iconFrame: target)],
                    retaining: nil
                ), "target")
            }
        }
    }

    func testInvalidGeometryIsIgnoredAndCannotMaskAValidCandidate() {
        let invalidFrames = [
            CGRect.zero,
            CGRect.null,
            CGRect.infinite,
            CGRect(x: 0, y: 0, width: -1, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: -1),
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 100),
        ]

        for invalid in invalidFrames {
            XCTAssertNil(FolderMergeGeometry.normalizedDistance(draggedIcon: invalid, targetIcon: icon))
            XCTAssertNil(FolderMergeGeometry.normalizedDistance(draggedIcon: icon, targetIcon: invalid))
            XCTAssertNil(target(for: invalid))
            XCTAssertEqual(FolderMergeGeometry.target(
                draggedIcon: icon,
                targets: [Target(id: "invalid", iconFrame: invalid), Target(id: "valid", iconFrame: icon)],
                retaining: "invalid"
            ), "valid")
        }
    }

    private var directions: [CGVector] {
        let diagonal = CGFloat(0.5).squareRoot()
        return [
            CGVector(dx: 1, dy: 0), CGVector(dx: -1, dy: 0),
            CGVector(dx: 0, dy: 1), CGVector(dx: 0, dy: -1),
            CGVector(dx: diagonal, dy: diagonal), CGVector(dx: diagonal, dy: -diagonal),
            CGVector(dx: -diagonal, dy: diagonal), CGVector(dx: -diagonal, dy: -diagonal),
        ]
    }

    private func translatedIcon(distance: CGFloat, direction: CGVector) -> CGRect {
        icon.offsetBy(dx: distance * direction.dx * icon.width, dy: distance * direction.dy * icon.height)
    }

    private func target(for dragged: CGRect, retaining: String? = nil) -> String? {
        FolderMergeGeometry.target(
            draggedIcon: dragged,
            targets: [Target(id: "target", iconFrame: icon)],
            retaining: retaining
        )
    }
}
