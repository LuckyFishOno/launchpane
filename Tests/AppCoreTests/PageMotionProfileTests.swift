@testable import AppCore
import XCTest

final class PageMotionProfileTests: XCTestCase {
    func testDiscretePagingUsesCalmerFullPageMotion() {
        let profile = PageMotionProfile.discrete

        XCTAssertEqual(profile.duration, 0.56)
        let initialScreenWidthsPerSecond =
            profile.firstControlPoint.y / profile.firstControlPoint.x / profile.duration
        XCTAssertLessThan(initialScreenWidthsPerSecond, 1)
        assertMonotonic(profile)
        assertEndsAtRest(profile)
    }

    func testSettlePreservesReleaseVelocityInBothDirectionsAndAtDifferentSizes() throws {
        for width in [800.0, 1710.0, 2560.0] {
            for direction in [-1.0, 1.0] {
                for fraction in [0.01, 0.1, 0.35, 0.8, 1.0] {
                    for screenWidthsPerSecond in [0.0, 0.05, 0.5, 2.0, 8.0] {
                        let delta = direction * width * fraction
                        let velocity = direction * width * screenWidthsPerSecond
                        let profile = try XCTUnwrap(PageMotionProfile.settle(
                            displayWidth: width,
                            targetDelta: delta,
                            releaseVelocity: velocity
                        ))

                        XCTAssertEqual(
                            initialVelocity(profile, targetDelta: delta),
                            velocity,
                            accuracy: max(1e-9, abs(velocity) * 1e-12)
                        )
                        XCTAssertGreaterThanOrEqual(profile.duration, 0.18)
                        XCTAssertLessThanOrEqual(profile.duration, 0.56)
                        assertMonotonic(profile)
                        assertEndsAtRest(profile)
                    }
                }
            }
        }
    }

    func testFastReleaseWithTinyResidualDoesNotClampVelocity() throws {
        let delta = -0.251
        let velocity = -13_680.0
        let profile = try XCTUnwrap(PageMotionProfile.settle(
            displayWidth: 1710,
            targetDelta: delta,
            releaseVelocity: velocity
        ))

        XCTAssertLessThan(profile.firstControlPoint.x, 0.001)
        XCTAssertEqual(initialVelocity(profile, targetDelta: delta), velocity, accuracy: 1e-8)
        assertMonotonic(profile)
        assertEndsAtRest(profile)
    }

    func testOpposingReleaseVelocityStartsRollbackAtRest() throws {
        for targetDelta in [-350.0, 350.0] {
            let profile = try XCTUnwrap(PageMotionProfile.settle(
                displayWidth: 1710,
                targetDelta: targetDelta,
                releaseVelocity: -targetDelta * 3
            ))

            XCTAssertEqual(initialVelocity(profile, targetDelta: targetDelta), 0)
            assertMonotonic(profile)
            assertEndsAtRest(profile)
        }
    }

    func testLongerRemainingTravelHasLongerSettleDuration() throws {
        let durations = try [0.3, 10.0, 100.0, 500.0, 1710.0].map { delta in
            try XCTUnwrap(PageMotionProfile.settle(
                displayWidth: 1710,
                targetDelta: delta,
                releaseVelocity: 0
            )).duration
        }

        XCTAssertEqual(durations, durations.sorted())
        XCTAssertEqual(try XCTUnwrap(durations.last), 0.56)
    }

    func testOversizedDistanceStillUsesBoundedDuration() throws {
        let profile = try XCTUnwrap(PageMotionProfile.settle(
            displayWidth: 800,
            targetDelta: 10_000,
            releaseVelocity: 700
        ))

        XCTAssertGreaterThanOrEqual(profile.duration, 0.18)
        XCTAssertLessThanOrEqual(profile.duration, 0.56)
        XCTAssertEqual(initialVelocity(profile, targetDelta: 10_000), 700, accuracy: 1e-9)
        assertMonotonic(profile)
    }

    func testInvalidInputsAndSubpixelTravelDoNotAnimate() {
        for width in [-100.0, 0, .infinity, -.infinity, .nan] {
            XCTAssertNil(PageMotionProfile.settle(
                displayWidth: width,
                targetDelta: 100,
                releaseVelocity: 500
            ))
        }
        for delta in [0.0, -0.25, 0.25, .infinity, -.infinity, .nan] {
            XCTAssertNil(PageMotionProfile.settle(
                displayWidth: 1710,
                targetDelta: delta,
                releaseVelocity: 500
            ))
        }
        for velocity in [Double.infinity, -.infinity, .nan] {
            XCTAssertNil(PageMotionProfile.settle(
                displayWidth: 1710,
                targetDelta: 100,
                releaseVelocity: velocity
            ))
        }
    }

    private func initialVelocity(_ profile: PageMotionProfile, targetDelta: Double) -> Double {
        targetDelta / profile.duration
            * profile.firstControlPoint.y / profile.firstControlPoint.x
    }

    private func assertEndsAtRest(
        _ profile: PageMotionProfile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let endingSlope = (1 - profile.secondControlPoint.y) / (1 - profile.secondControlPoint.x)
        XCTAssertEqual(endingSlope, 0, file: file, line: line)
    }

    private func assertMonotonic(
        _ profile: PageMotionProfile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let p1 = profile.firstControlPoint
        let p2 = profile.secondControlPoint
        XCTAssertGreaterThan(p1.x, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(p1.x, p2.x, file: file, line: line)
        XCTAssertLessThan(p2.x, 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(p1.y, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(p1.y, p2.y, file: file, line: line)
        XCTAssertLessThanOrEqual(p2.y, 1, file: file, line: line)

        // Sample the actual parametric curve, not only its control-point bounds.
        var previousX = 0.0
        var previousY = 0.0
        for step in 1...200 {
            let progress = Double(step) / 200
            let remaining = 1 - progress
            let sampleX = 3 * remaining * remaining * progress * p1.x
                + 3 * remaining * progress * progress * p2.x + progress * progress * progress
            let sampleY = 3 * remaining * remaining * progress * p1.y
                + 3 * remaining * progress * progress * p2.y + progress * progress * progress
            XCTAssertGreaterThan(sampleX, previousX, file: file, line: line)
            XCTAssertGreaterThanOrEqual(sampleY, previousY, file: file, line: line)
            XCTAssertLessThanOrEqual(sampleY, 1, file: file, line: line)
            previousX = sampleX
            previousY = sampleY
        }
    }
}
