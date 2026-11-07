import Foundation
import Combine
@preconcurrency import Vision
@preconcurrency import CoreML
@preconcurrency import CoreImage
import DiceCaptureCore

struct RecognizedDie: Identifiable, Sendable {
    let id: Int
    let value: Int
    let confidence: Float
    let box: CGRect
}

/// A single in-flight request: drop frames rather than queue stale camera images.
final class DiceRecognizer: ObservableObject, @unchecked Sendable {
    @Published private(set) var dice: [RecognizedDie] = []
    @Published private(set) var settled = false
    @Published private(set) var message = "Waiting for camera…"
    private let queue = DispatchQueue(label: "org.boardgamescafe.dicetower.recognition", qos: .userInitiated)
    private let gate = DispatchSemaphore(value: 1)
    private let lock = NSLock()
    private var generation = 0
    private let context = CIContext()
    private var model: VNCoreMLModel?
    private var previous: [RecognizedDie] = []
    private var agreement = 0
    private var lastResultTime = -Double.infinity
    private var lastSubmission = -Double.infinity // camera queue only

    func reset(_ message: String = "Waiting for a still scene…") {
        lock.lock(); generation += 1; lock.unlock()
        queue.async { self.previous = []; self.agreement = 0; self.lastResultTime = -.infinity }
        DispatchQueue.main.async { self.dice = []; self.settled = false; self.message = message }
    }

    func submit(_ image: CIImage, region: CaptureRegion, still: Bool, timestamp: Double) {
        guard timestamp - lastSubmission >= 0.25, gate.wait(timeout: .now()) == .success else { return }
        lastSubmission = timestamp
        lock.lock(); let epoch = generation; lock.unlock()
        queue.async {
            defer { self.gate.signal() }
            do {
                if self.model == nil {
                    guard let url = Bundle.main.url(forResource: "DiceTowerD6", withExtension: "mlmodelc") else { throw RecognitionError.missingModel }
                    let configuration = MLModelConfiguration(); configuration.computeUnits = .all
                    self.model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration))
                }
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
                try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([request])
                let result = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { observation -> RecognizedDie? in
                    guard let label = observation.labels.first, let value = Int(label.identifier), (1...6).contains(value) else { return nil }
                    let confidence = observation.confidence * label.confidence
                    guard confidence >= 0.75, let box = geometry.cameraBox(fromVision: observation.boundingBox) else { return nil }
                    return RecognizedDie(id: 0, value: value, confidence: confidence, box: box)
                }.sorted { $0.box.midX < $1.box.midX }.enumerated().map { RecognizedDie(id: $0.offset, value: $0.element.value, confidence: $0.element.confidence, box: $0.element.box) }
                let matches = result.count == self.previous.count && zip(result, self.previous).allSatisfy {
                    $0.value == $1.value && abs($0.box.midX - $1.box.midX) < 0.025 && abs($0.box.midY - $1.box.midY) < 0.025
                }
                self.agreement = still && matches && timestamp - self.lastResultTime < 1 ? self.agreement + 1 : 0
                self.previous = result; self.lastResultTime = timestamp
                let settled = still && self.agreement >= 2
                DispatchQueue.main.async {
                    self.lock.lock(); let valid = epoch == self.generation; self.lock.unlock()
                    guard valid else { return }
                    self.dice = result; self.settled = settled
                    self.message = settled ? (result.isEmpty ? "No dice detected · check the tray" : "Settled · check the highlighted faces") : "Waiting for a steady reading…"
                }
            } catch {
                DispatchQueue.main.async {
                    self.lock.lock(); let valid = epoch == self.generation; self.lock.unlock()
                    guard valid else { return }
                    self.dice = []; self.settled = false; self.message = "Recognition unavailable: \(error.localizedDescription)"
                }
            }
        }
    }
    private enum RecognitionError: LocalizedError {
        case missingModel, image
        var errorDescription: String? { self == .missingModel ? "Bundled model is missing." : "Could not prepare camera image." }
    }
}
