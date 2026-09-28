import Foundation

/// The remaining samples of an opacity curve when a presentation reverses.
struct OpacityCurveSegment {
    let values: [Float]
    let keyTimes: [NSNumber]
    let remainingTimeFraction: CFTimeInterval

    static func make(curve: [Float], startingAt startOpacity: Float) -> OpacityCurveSegment {
        guard curve.count >= 2 else {
            return OpacityCurveSegment(
                values: [startOpacity, curve.last ?? startOpacity], keyTimes: [0, 1], remainingTimeFraction: 1)
        }
        let clampedStart = min(1, max(0, startOpacity))
        guard let position = curvePosition(curve: curve, opacity: clampedStart) else {
            let endOpacity = curve.last ?? clampedStart
            return OpacityCurveSegment(
                values: [clampedStart, endOpacity], keyTimes: [0, 1],
                remainingTimeFraction: abs(endOpacity - clampedStart) < 0.001 ? 0 : 1)
        }
        let step = 1.0 / Double(curve.count - 1)
        let startTime = (Double(position.index) + position.interpolation) * step
        let remainingTime = max(0.000_001, 1 - startTime)
        var values: [Float] = [clampedStart]
        var absoluteTimes: [Double] = [startTime]
        for index in (position.index + 1)..<curve.count {
            let time = Double(index) * step
            if time <= startTime + 0.000_001 { continue }
            values.append(curve[index])
            absoluteTimes.append(time)
        }
        if values.count == 1 {
            values.append(curve.last ?? clampedStart)
            absoluteTimes.append(1)
        }
        var keyTimes = absoluteTimes.map { absoluteTime -> NSNumber in
            let normalized = (absoluteTime - startTime) / remainingTime
            return NSNumber(value: min(1, max(0, normalized)))
        }
        if !keyTimes.isEmpty { keyTimes[keyTimes.count - 1] = 1 }
        return OpacityCurveSegment(
            values: values, keyTimes: keyTimes, remainingTimeFraction: CFTimeInterval(remainingTime))
    }

    private static func curvePosition(curve: [Float], opacity: Float) -> (index: Int, interpolation: Double)? {
        for index in 0..<(curve.count - 1) {
            let startSample = curve[index]
            let endSample = curve[index + 1]
            let low = min(startSample, endSample) - 0.000_001
            let high = max(startSample, endSample) + 0.000_001
            guard opacity >= low, opacity <= high else { continue }
            let delta = endSample - startSample
            let interpolation = abs(delta) > 0.000_001 ? Double((opacity - startSample) / delta) : 0
            return (index, min(1, max(0, interpolation)))
        }
        return nil
    }

}
