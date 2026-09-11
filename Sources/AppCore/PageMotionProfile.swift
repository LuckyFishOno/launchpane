import Foundation

/// A monotonic cubic timing curve, independent of Core Animation, so paging
/// velocity and duration can be verified without running the application UI.
public struct PageMotionProfile: Equatable, Sendable {
    public struct ControlPoint: Equatable, Sendable {
        public let x: Double
        public let y: Double
    }

    public let duration: TimeInterval
    public let firstControlPoint: ControlPoint
    public let secondControlPoint: ControlPoint

    /// A wheel notch starts from rest; give the full-page movement a perceptible
    /// acceleration phase instead of covering most of the screen immediately.
    public static let discrete = PageMotionProfile(
        duration: 0.56,
        firstControlPoint: ControlPoint(x: 0.24, y: 0.12),
        secondControlPoint: ControlPoint(x: 0.28, y: 1)
    )

    /// Continues a finger-driven translation using its velocity toward the final
    /// position. The caller must use this duration unchanged: stretching it after
    /// computing the curve would introduce a speed discontinuity at release.
    public static func settle(
        displayWidth: Double,
        targetDelta: Double,
        releaseVelocity: Double
    ) -> PageMotionProfile? {
        guard
            displayWidth.isFinite, displayWidth > 0,
            targetDelta.isFinite, abs(targetDelta) > 0.25,
            releaseVelocity.isFinite
        else { return nil }

        let distance = abs(targetDelta)
        let fraction = min(1, distance / displayWidth)
        let targetSign = targetDelta > 0 ? 1.0 : -1.0
        // A rollback can oppose the finger's last movement. Starting from zero
        // avoids carrying that velocity beyond the allowed page interval.
        let velocityTowardTarget = max(0, releaseVelocity * targetSign)
        let normalizedSpeed = velocityTowardTarget / displayWidth
        let distanceDuration = 0.18 + 0.38 * pow(fraction, 0.72)
        let velocityReduction = min(0.04, normalizedSpeed * 0.018)
        let duration = min(0.56, max(0.18, distanceDuration - velocityReduction))

        // For a cubic Bezier timing function dy/dx at its start is y1/x1.
        // Shrinking x1, rather than clamping y1 or stretching time afterwards,
        // preserves even a fast release over a short remaining distance.
        let initialSlope = velocityTowardTarget * duration / distance
        guard initialSlope.isFinite else { return nil }
        let x1 = initialSlope > 0 ? min(0.24, 0.85 / initialSlope) : 0.24
        let y1 = x1 * initialSlope
        guard x1 > 0 else { return nil }

        return PageMotionProfile(
            duration: duration,
            firstControlPoint: ControlPoint(x: x1, y: y1),
            secondControlPoint: ControlPoint(x: 0.64, y: 1)
        )
    }
}
