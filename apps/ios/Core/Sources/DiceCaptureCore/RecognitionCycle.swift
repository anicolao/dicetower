import Foundation

/// Monotonic-time policy; camera availability may make actual starts later than a deadline.
public struct RecognitionCycle: Sendable {
    public private(set) var inferenceMs = 0.0
    public private(set) var emaInferenceMs = 0.0
    public private(set) var processingMs = 0.0
    public private(set) var intervalMs = 50.0
    public private(set) var inferenceCount = 0
    public private(set) var agreementCount = 0
    public private(set) var quiescent = false
    public private(set) var nextStart = -Double.infinity
    private var previous: [RollFace]?
    private var startedAt = 0.0
    public init() {}
    public mutating func reset() {
        previous = nil; agreementCount = 0; quiescent = false; nextStart = -.infinity
    }
    public func canStart(at time: Double) -> Bool { !quiescent && time + 1e-9 >= nextStart }
    public mutating func started(at time: Double) { startedAt = time }
    /// Returns true only on the second consecutive agreeing still-scene inference.
    public mutating func completed(faces: [RollFace], still: Bool, inferenceMs: Double, processingMs: Double, at time: Double) -> Bool {
        record(inferenceMs: inferenceMs, processingMs: processingMs, at: time)
        guard still else { previous = nil; agreementCount = 0; return false }
        if let previous, Self.matches(faces, previous) { agreementCount += 1 }
        else { agreementCount = 1 }
        self.previous = faces
        if agreementCount >= 2 { agreementCount = 2; quiescent = true; return true }
        return false
    }
    /// Keep timing observations from invalidated requests, but never accept their result.
    public mutating func discarded(inferenceMs: Double, processingMs: Double, at time: Double) {
        record(inferenceMs: inferenceMs, processingMs: processingMs, at: time)
        previous = nil; agreementCount = 0
    }
    private mutating func record(inferenceMs: Double, processingMs: Double, at time: Double) {
        self.inferenceMs = max(0, inferenceMs); self.processingMs = max(0, processingMs)
        emaInferenceMs = inferenceCount == 0 ? self.inferenceMs : 0.2 * self.inferenceMs + 0.8 * emaInferenceMs
        inferenceCount += 1
        intervalMs = max(50, ceil((emaInferenceMs - 1e-9) / 50) * 50)
        // Start-to-start cadence. If work overran, use the next 50ms clock boundary.
        nextStart = max(startedAt + intervalMs / 1000, ceil((time - 1e-9) / 0.05) * 0.05)
    }
    public static func matches(_ a: [RollFace], _ b: [RollFace]) -> Bool {
        guard a.count == b.count else { return false }
        var remaining = b
        for face in a {
            guard let i = remaining.firstIndex(where: {
                $0.value == face.value && abs(($0.box.x + $0.box.width / 2) - (face.box.x + face.box.width / 2)) < 0.025 &&
                abs(($0.box.y + $0.box.height / 2) - (face.box.y + face.box.height / 2)) < 0.025
            }) else { return false }
            remaining.remove(at: i)
        }
        return true
    }
}
