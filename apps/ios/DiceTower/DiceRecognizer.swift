import Foundation
import Combine
@preconcurrency import Vision
@preconcurrency import CoreML
@preconcurrency import CoreImage
import DiceCaptureCore
import UIKit

struct RecognizedDie: Identifiable, Sendable {
    let id: Int
    let value: Int
    let confidence: Float
    let box: CGRect
}

struct RecognitionMetrics: Codable, Sendable {
    var schemaVersion = 1
    var metricId: String
    let sessionId: String
    var recordedAt: Double
    let phase: String
    let inferenceMs: Double
    let emaInferenceMs: Double
    let processingMs: Double
    let intervalMs: Double
    let inferenceCount: Int
    let agreementCount: Int
    var settleMs = 200
    var eventId: String
    // Optional so pre-upgrade metrics in the durable outbox decode/retry unchanged.
    var duplicateDiscarded: Bool?
    var duplicateCount: Int?
    var duplicateOfEventId: String?
    var uploadHeldCount: Int?
    var uploadIssue: String?
    var deliveryEventId: String?
    var deliveryState: String?
    var deliveryValues: String?
    var deliveryDetail: String?
    var deliveryAt: Double?
}

/// Fresh frames only, a single in-flight request, and no ML work while quiescent.
final class DiceRecognizer: ObservableObject, @unchecked Sendable {
    @Published private(set) var dice: [RecognizedDie] = []
    @Published private(set) var settled = false
    @Published private(set) var message = "Waiting for camera…"
    @Published private(set) var metrics: RecognitionMetrics?
    private let queue = DispatchQueue(label: "org.boardgamescafe.dicetower.recognition", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var busy = false
    private var scheduled = false
    private var latest: Frame?
    private var lastUsedTimestamp = -Double.infinity
    private struct Frame: @unchecked Sendable {
        let image: CIImage
        let region: CaptureRegion
        let still: Bool
        let timestamp: Double
        let capturedAt: Double
    }
    private var phase = "active"
    private var cycle = RecognitionCycle()
    private let sessionID = UUID().uuidString
    private let context = CIContext()
    private var model: VNCoreMLModel?
    private var eventGate = RollEventGate() // inference queue only
    private var reportedFilter = ReportedRollFilter() // lock protects delivery and snapshots
    private var duplicateCount = 0
    var onRoll: ((CloudRoll) -> Void)?
    var onMetrics: ((RecognitionMetrics) -> Void)?

    func deliveryFailed(eventID: String) {
        lock.lock(); let cleared = reportedFilter.failed(eventID: eventID); lock.unlock()
        // Keep the current still scene quiet. Its next motion/restart can report
        // again; do not spin on a permanently invalid payload.
        if cleared { queue.async { self.eventGate.moved() } }
    }

    // Caller holds lock. Timing uses a monotonic clock; recordedAt is for stream display.
    private func snapshot(eventID: String = "", duplicateOf: String = "") -> RecognitionMetrics {
        RecognitionMetrics(metricId: UUID().uuidString, sessionId: sessionID, recordedAt: Date().timeIntervalSince1970 * 1000,
                           phase: phase, inferenceMs: cycle.inferenceMs, emaInferenceMs: cycle.emaInferenceMs,
                           processingMs: cycle.processingMs, intervalMs: cycle.intervalMs, inferenceCount: cycle.inferenceCount,
                           agreementCount: cycle.agreementCount, eventId: eventID,
                           duplicateDiscarded: !duplicateOf.isEmpty, duplicateCount: duplicateCount, duplicateOfEventId: duplicateOf)
    }
    func reset(_ message: String = "Waiting for dice to settle…", newRoll: Bool = false, phase: String = "active", clearReportedHistory: Bool = false) {
        lock.lock()
        generation += 1; cycle.reset(); self.phase = phase
        if clearReportedHistory { reportedFilter = ReportedRollFilter() }
        latest = nil; lastUsedTimestamp = -.infinity; scheduled = false
        let sample = snapshot()
        if newRoll { queue.async { self.eventGate.moved() } }
        lock.unlock()
        DispatchQueue.main.async {
            self.dice = []; self.settled = false; self.message = message
            self.metrics = sample; self.onMetrics?(sample)
        }
    }

    func submit(_ image: CIImage, region: CaptureRegion, still: Bool, timestamp: Double) {
        lock.lock()
        guard phase == "active" else { lock.unlock(); return }
        latest = Frame(image: image, region: region, still: still, timestamp: timestamp, capturedAt: Date().timeIntervalSince1970 * 1000)
        lock.unlock()
        scheduleLatest()
    }
    private func scheduleLatest() {
        lock.lock()
        guard phase == "active", !busy, !scheduled, let latest, latest.timestamp > lastUsedTimestamp else { lock.unlock(); return }
        scheduled = true
        let epoch = generation
        let delay = max(0, cycle.nextStart - ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) {
            self.lock.lock()
            guard epoch == self.generation else { self.lock.unlock(); return }
            self.scheduled = false
            guard self.phase == "active", !self.busy, let frame = self.latest, frame.timestamp > self.lastUsedTimestamp else { self.lock.unlock(); return }
            self.busy = true; self.lastUsedTimestamp = frame.timestamp
            self.cycle.started(at: ProcessInfo.processInfo.systemUptime)
            self.lock.unlock()
            self.infer(frame, epoch: epoch)
        }
    }
    private func infer(_ frame: Frame, epoch: Int) {
        let image = frame.image, region = frame.region, still = frame.still, capturedAt = frame.capturedAt
        defer {
            lock.lock(); busy = false; lock.unlock()
            scheduleLatest()
        }
        do {
            if self.model == nil {
                guard let url = Bundle.main.url(forResource: "DiceTowerD6", withExtension: "mlmodelc") else { throw RecognitionError.missingModel }
                let configuration = MLModelConfiguration(); configuration.computeUnits = .all
                self.model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration))
            }
            let processingStart = ProcessInfo.processInfo.systemUptime
            let geometry = RecognitionGeometry(imageSize: image.extent.size, region: region)
            let crop = CGRect(x: geometry.crop.minX, y: image.extent.height - geometry.crop.maxY,
                              width: geometry.crop.width, height: geometry.crop.height)
            let cropped = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            let resized = cropped.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: geometry.scaleY, kCIInputAspectRatioKey: geometry.scaleX / geometry.scaleY])
                .transformed(by: CGAffineTransform(translationX: geometry.padding.x, y: geometry.padding.y))
            let square = resized.composited(over: CIImage(color: .black)).cropped(to: CGRect(x: 0, y: 0, width: 416, height: 416))
            guard let cg = self.context.createCGImage(square, from: square.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw RecognitionError.image }
            let request = VNCoreMLRequest(model: self.model!)
            request.imageCropAndScaleOption = .scaleFill // already cropped and letterboxed
            let modelStart = ProcessInfo.processInfo.systemUptime
            try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([request])
            let inferenceMs = (ProcessInfo.processInfo.systemUptime - modelStart) * 1000
            let result = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { observation -> RecognizedDie? in
                guard let label = observation.labels.first, let value = Int(label.identifier), (1...6).contains(value) else { return nil }
                let score = observation.confidence * label.confidence
                guard score.isFinite else { return nil }
                let confidence = min(1, max(0, score))
                guard confidence >= 0.75, let box = geometry.cameraBox(fromVision: observation.boundingBox) else { return nil }
                return RecognizedDie(id: 0, value: value, confidence: confidence, box: box)
            }.sorted { $0.box.midX < $1.box.midX }.enumerated().map { RecognizedDie(id: $0.offset, value: $0.element.value, confidence: $0.element.confidence, box: $0.element.box) }
            let finished = ProcessInfo.processInfo.systemUptime
            let processingMs = (finished - processingStart) * 1000
            let faces = try RollUploadValidation.faces(result.map { RollFace(value: $0.value, confidence: Double($0.confidence), box: $0.box) })
            self.lock.lock()
            let valid = epoch == self.generation
            let report: Bool
            if valid {
                report = self.cycle.completed(faces: faces, still: still, inferenceMs: inferenceMs, processingMs: processingMs, at: finished)
                if report { self.phase = "quiescent" }
            } else {
                self.cycle.discarded(inferenceMs: inferenceMs, processingMs: processingMs, at: finished); report = false
            }
            let duplicateOf = report ? (self.reportedFilter.duplicateEventID(for: faces) ?? "") : ""
            self.lock.unlock()
            var event: CloudRoll?
            if report, duplicateOf.isEmpty, let decision = self.eventGate.accept(faces) {
                let scale = min(1, 384 / image.extent.width, 512 / image.extent.height)
                let thumbnail = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
                guard let cg = self.context.createCGImage(thumbnail, from: thumbnail.extent),
                      let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.6), jpeg.count < 74000 else { throw RecognitionError.image }
                event = CloudRoll(eventId: UUID().uuidString, rollId: decision.rollID, kind: decision.kind,
                                  capturedAt: capturedAt, dice: faces, count: faces.count,
                                  total: faces.reduce(0) { $0 + $1.value }, thumbnail: "data:image/jpeg;base64," + jpeg.base64EncodedString())
            }
            let emittedEvent = event
            DispatchQueue.main.async {
                self.lock.lock()
                let current = epoch == self.generation
                if current {
                    if !duplicateOf.isEmpty { self.duplicateCount += 1 }
                    if let emittedEvent { self.reportedFilter.record(faces, eventID: emittedEvent.eventId) }
                }
                let sample = self.snapshot(eventID: current ? (emittedEvent?.eventId ?? "") : "", duplicateOf: current ? duplicateOf : "")
                self.lock.unlock()
                self.metrics = sample; self.onMetrics?(sample)
                guard current else { return }
                self.dice = result; self.settled = report
                if let emittedEvent { self.onRoll?(emittedEvent) }
                self.message = !duplicateOf.isEmpty ? "Quiescent · duplicate discarded · watching for motion" : report ? (result.isEmpty ? "Quiescent · no dice detected · watching for motion" : "Quiescent · reading ready · watching for motion") : "Recognizing · waiting for two agreeing still frames…"
            }
        } catch {
            self.lock.lock(); let valid = epoch == self.generation
            if valid { self.phase = "error"; self.cycle.reset() }
            let sample = self.snapshot(); self.lock.unlock()
            DispatchQueue.main.async {
                self.metrics = sample; self.onMetrics?(sample)
                guard valid else { return }
                self.dice = []; self.settled = false; self.message = "Recognition unavailable: \(error.localizedDescription)"
            }
        }
    }
    private enum RecognitionError: LocalizedError {
        case missingModel, image
        var errorDescription: String? { self == .missingModel ? "Bundled model is missing." : "Could not prepare camera image." }
    }
}
