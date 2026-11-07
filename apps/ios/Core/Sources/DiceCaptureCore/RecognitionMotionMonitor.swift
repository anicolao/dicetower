import Foundation

public struct RecognitionMotionObservation: Sendable {
    public let still: Bool
    public let invalidated: Bool
    public let newRoll: Bool
}

/// Recognition needs evidence of a movement episode, not photo-capture invalidation.
public struct RecognitionMotionMonitor: Sendable {
    public var parameters = CaptureParameters(settleDuration: 0.2)
    private var previous: AnalysisFrame?
    private var anchor: AnalysisFrame?
    private var last: Double?
    private var quietSince: Double?
    private var sceneReference: AnalysisFrame?
    private var changeSamples = 0
    private var quietSamples = 0
    private var movementReported = false
    private var still = false

    public init() {}
    public mutating func reset() {
        let settings = parameters
        self = Self(); parameters = settings
    }

    public mutating func observe(_ frame: AnalysisFrame, at time: Double) -> RecognitionMotionObservation {
        let wasStill = still
        guard frame.isValid, time.isFinite else {
            still = false; changeSamples = 0
            return .init(still: false, invalidated: true, newRoll: false)
        }
        defer { previous = frame; last = time }
        let gap = last.map { time <= $0 || time - $0 > parameters.maximumFrameGap } ?? false
        guard let previous, previous.width == frame.width, previous.height == frame.height, !gap else {
            still = false; anchor = frame; quietSince = time; quietSamples = 1; changeSamples = 0
            return .init(still: false, invalidated: wasStill || gap, newRoll: false)
        }
        var newRoll = false
        // Compare with the settled scene, not only adjacent frames: a quick roll
        // may already have stopped by the second observation. One transient frame
        // returning to the old scene clears the candidate instead of rearming.
        if frame.spatialDifference(from: sceneReference ?? previous) > parameters.motionThreshold {
            changeSamples += 1
            if changeSamples >= 2 && !movementReported {
                newRoll = true; movementReported = true
                if still { still = false; anchor = frame; quietSince = time; quietSamples = 1 }
            }
        } else { changeSamples = 0 }
        if frame.spatialDifference(from: previous) > parameters.motionThreshold {
            still = false; anchor = nil; quietSince = nil; quietSamples = 0
        } else {
            if quietSince == nil || frame.difference(from: previous) > parameters.motionThreshold ||
                (anchor.map { frame.difference(from: $0) } ?? 0) > parameters.motionThreshold {
                still = false; anchor = frame; quietSince = time; quietSamples = 1
            } else {
                quietSamples += 1
                if time - (quietSince ?? time) + 1e-9 >= 0.2 && quietSamples >= 3 {
                    if !still { sceneReference = frame; changeSamples = 0; movementReported = false }
                    still = true
                }
            }
        }
        return .init(still: still, invalidated: wasStill && !still, newRoll: newRoll)
    }
}

extension AnalysisFrame {
    /// Remove a uniform luminance offset before measuring spatial motion. Raw
    /// differences still govern settlement, so exposure changes cannot settle early.
    public func spatialDifference(from other: AnalysisFrame) -> Double {
        guard isValid, other.isValid, width == other.width, height == other.height else { return 1 }
        let offset = zip(pixels, other.pixels).reduce(0.0) { $0 + Double(Int($1.0) - Int($1.1)) } / Double(pixels.count)
        var sum = 0.0, localMaximum = 0.0
        for y in stride(from: 0, to: height, by: 12) {
            for x in stride(from: 0, to: width, by: 12) {
                var local = 0.0, count = 0.0
                for yy in y..<min(y + 12, height) { for xx in x..<min(x + 12, width) {
                    let i = yy * width + xx
                    local += abs(Double(Int(pixels[i]) - Int(other.pixels[i])) - offset); count += 1
                } }
                sum += local; localMaximum = max(localMaximum, local / count / 255)
            }
        }
        return max(sum / Double(pixels.count) / 255, localMaximum / 3)
    }
}
