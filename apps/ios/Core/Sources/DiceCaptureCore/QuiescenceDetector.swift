import Foundation

public struct CaptureParameters: Codable, Equatable, Sendable {
    public var settleDuration: Double
    public var motionThreshold: Double
    public var minimumMotionDuration: Double
    public var maximumFrameGap: Double

    public init(settleDuration: Double = 1.2, motionThreshold: Double = 0.012,
                minimumMotionDuration: Double = 0.15, maximumFrameGap: Double = 0.6) {
        self.settleDuration = settleDuration
        self.motionThreshold = motionThreshold
        self.minimumMotionDuration = minimumMotionDuration
        self.maximumFrameGap = maximumFrameGap
    }
}

/// Small upright luminance frame covering only the user-selected tray region.
public struct AnalysisFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }
    public var isValid: Bool { width > 0 && height > 0 && pixels.count == width * height }

    /// Local tiles keep a single small moving die from being diluted by a large tray.
    public func difference(from other: AnalysisFrame) -> Double {
        guard isValid, other.isValid, width == other.width, height == other.height else { return 1 }
        let tile = 12
        var sum = 0.0, localMaximum = 0.0
        for y in stride(from: 0, to: height, by: tile) {
            for x in stride(from: 0, to: width, by: tile) {
                var localSum = 0.0, count = 0.0
                for yy in y..<min(y + tile, height) {
                    for xx in x..<min(x + tile, width) {
                        let i = yy * width + xx
                        localSum += Double(abs(Int(pixels[i]) - Int(other.pixels[i])))
                        count += 1
                    }
                }
                sum += localSum
                localMaximum = max(localMaximum, localSum / count / 255)
            }
        }
        return max(sum / Double(pixels.count) / 255, localMaximum / 3)
    }
}

public enum CapturePhase: String, Codable, Sendable {
    case settling, moving, waitingForMovement, capturing
}

public struct MotionObservation: Sendable {
    public let phase: CapturePhase
    public let score: Double
    public let progress: Double
    public let shouldCapture: Bool
}

/// One photo per motion episode. No ML, dice values, or expected dice count.
public struct QuiescenceDetector: Sendable {
    public var parameters: CaptureParameters
    private var previous: AnalysisFrame?
    private var stableAnchor: AnalysisFrame?
    private var waitingReference: AnalysisFrame?
    private var stableSince: Double?
    private var movementSince: Double?
    private var lastTimestamp: Double?
    private var quietSamples = 0
    private var observedMovement = true
    private var pending = false
    private var invalidated = false
    private var cooldownUntil = 0.0

    public init(parameters: CaptureParameters = .init()) { self.parameters = parameters }
    public var pendingCaptureIsValid: Bool { pending && !invalidated }

    public mutating func reset(requireMovement: Bool = false) {
        let settings = parameters
        self = Self(parameters: settings)
        observedMovement = !requireMovement
    }

    public mutating func completeCapture(saved: Bool, at timestamp: Double) {
        pending = false; invalidated = false; stableSince = nil; stableAnchor = nil
        movementSince = nil; quietSamples = 0
        observedMovement = !saved
        if saved { waitingReference = previous; cooldownUntil = timestamp + 0.8 }
    }

    public mutating func observe(_ frame: AnalysisFrame, at timestamp: Double) -> MotionObservation {
        func result(_ phase: CapturePhase, _ score: Double = 0, _ progress: Double = 0, _ capture: Bool = false) -> MotionObservation {
            .init(phase: phase, score: score, progress: progress, shouldCapture: capture)
        }
        guard frame.isValid, timestamp.isFinite else { return result(.moving, 1) }
        defer { previous = frame; lastTimestamp = timestamp }
        if let lastTimestamp, timestamp <= lastTimestamp || timestamp - lastTimestamp > parameters.maximumFrameGap {
            stableSince = nil; stableAnchor = nil; movementSince = nil; quietSamples = 0
            if pending { invalidated = true }
            return result(pending ? .capturing : .moving)
        }
        guard let previous, previous.width == frame.width, previous.height == frame.height else {
            stableSince = timestamp; stableAnchor = frame; quietSamples = 1
            return result(observedMovement ? .settling : .waitingForMovement)
        }
        let score = frame.difference(from: previous)
        if pending {
            if score > parameters.motionThreshold || (stableAnchor.map { frame.difference(from: $0) } ?? 0) > parameters.motionThreshold {
                invalidated = true
            }
            return result(.capturing, score)
        }
        if timestamp < cooldownUntil { return result(.waitingForMovement, score) }
        if score > parameters.motionThreshold {
            if movementSince == nil { movementSince = timestamp }
            if timestamp - (movementSince ?? timestamp) >= parameters.minimumMotionDuration { observedMovement = true }
            stableSince = nil; stableAnchor = nil; quietSamples = 0
            return result(.moving, score)
        }
        movementSince = nil
        if !observedMovement {
            // Slow scene changes also rearm, even when adjacent frames differ little.
            if let waitingReference, frame.difference(from: waitingReference) > parameters.motionThreshold * 2 {
                observedMovement = true
            } else { return result(.waitingForMovement, score) }
        }
        if stableAnchor == nil || stableSince == nil {
            stableAnchor = frame; stableSince = timestamp; quietSamples = 0
        }
        if let stableAnchor, frame.difference(from: stableAnchor) > parameters.motionThreshold {
            self.stableAnchor = frame; stableSince = timestamp; quietSamples = 0
            return result(.moving, score)
        }
        quietSamples += 1
        let duration = max(0, timestamp - (stableSince ?? timestamp))
        if duration >= parameters.settleDuration && quietSamples >= 3 {
            pending = true; invalidated = false; stableAnchor = frame
            return result(.capturing, score, 1, true)
        }
        return result(.settling, score, min(1, duration / parameters.settleDuration))
    }
}
