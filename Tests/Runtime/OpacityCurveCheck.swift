// Pure curve checks; compile with OpacityCurveSegment.swift, without AppKit.
import Foundation

@main
struct OpacityCurveCheck {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        let opening = OpacityCurveSegment.make(curve: [0, 0.25, 1], startingAt: 0.125)
        check(opening.values == [0.125, 0.25, 1], "Opening begins at the visible opacity")
        check(abs(opening.remainingTimeFraction - 0.75) < 0.000_001, "Opening retains the remaining time")
        check(abs(opening.keyTimes[1].doubleValue - 1 / 3.0) < 0.000_001, "Key times are renormalized")
        let closing = OpacityCurveSegment.make(curve: [1, 0.75, 0], startingAt: 0.875)
        check(closing.values == [0.875, 0.75, 0], "Closing follows descending samples")
        check(closing.keyTimes == opening.keyTimes, "Reversing the curve preserves relative timing")
        check(closing.remainingTimeFraction == opening.remainingTimeFraction, "Directions preserve equal durations")
        let empty = OpacityCurveSegment.make(curve: [], startingAt: 0.4)
        check(empty.values == [0.4, 0.4] && empty.keyTimes == [0, 1], "Empty input is a constant curve")
        let single = OpacityCurveSegment.make(curve: [1], startingAt: 0.4)
        check(single.values == [0.4, 1] && single.remainingTimeFraction == 1, "One sample keeps the full duration")
        for curve: [Float] in [[0, 0.25, 1], [1, 0.75, 0]] {
            for step in 0...100 {
                let opacity = Float(step) / 100
                let segment = OpacityCurveSegment.make(curve: curve, startingAt: opacity)
                check(segment.values.first == opacity && segment.values.last == curve.last,
                      "Every reversal keeps its exact endpoints")
                check(segment.values.count == segment.keyTimes.count, "Every value has a key time")
                check(segment.keyTimes.first == 0 && segment.keyTimes.last == 1, "Time spans the full animation")
                check(zip(segment.keyTimes, segment.keyTimes.dropFirst()).allSatisfy {
                    $0.doubleValue <= $1.doubleValue
                }, "Time never runs backward")
                check(segment.remainingTimeFraction > 0 && segment.remainingTimeFraction <= 1,
                      "Remaining duration is positive and bounded")
            }
        }
        print("OPACITY CURVE: \(checks) assertions passed")
    }
}
