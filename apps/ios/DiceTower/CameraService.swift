import Foundation
import Combine
import CoreImage
@preconcurrency import AVFoundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import DiceCaptureCore

/// AVFoundation configuration, frame analysis, and capture ownership share one queue.
final class CameraService: NSObject, ObservableObject, @unchecked Sendable {
    let session = AVCaptureSession()
    let recognizer = DiceRecognizer()
    private var recognitionMotion = RecognitionMotionMonitor()
    private var recognitionStill = false
    private let queue = DispatchQueue(label: "org.boardgamescafe.dicetower.camera", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var recognitionRunning = false
    private var runningAuto = false
    private var detector = QuiescenceDetector()
    private var region = CaptureRegion()
    private var lastAnalysisTime = -Double.infinity
    private var lastFrameTime = 0.0
    private var lastFrameArrival = 0.0
    private var lastScore = 0.0
    private var pending: PendingShot?
    private var pendingInvalidatedAt: Double?
    private var locked = false
    private var corpusSessionID: UUID?
    private var observers: [NSObjectProtocol] = []

    @Published private(set) var ready = false
    @Published private(set) var automatic = false
    @Published private(set) var saving = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var status = "Preparing camera…"
    @Published private(set) var progress = 0.0
    @Published private(set) var motionScore = 0.0
    @Published private(set) var demoImage: UIImage?
    @Published private(set) var isDemo = false
    var onPhoto: ((Data, Data?, CaptureRecord, UUID) -> Void)?
    var onError: ((String) -> Void)?

    private struct PendingShot {
        let id: Int64
        let corpusSessionID: UUID
        let frameTimestamp: Double
        let trigger: String
        let createdAt: Date
        let parameters: CaptureParameters
        let region: CaptureRegion
        let score: Double
    }

    override init() {
        super.init()
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.pauseForInterruption()
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-capture-demo") {
            startDemo(); return
        }
        #endif
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: queue.async { self.configureAndStart() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                guard let self else { return }
                if allowed { self.queue.async { self.configureAndStart() } }
                else { self.showPermissionDenied() }
            }
        default: showPermissionDenied()
        }
    }

    func suspend() {
        setAutomatic(false)
        recognizer.reset("Camera paused", phase: "paused")
        queue.async {
            self.recognitionRunning = false
            self.recognitionMotion.reset(); self.recognitionStill = false
            self.detector.reset()
            if self.session.isRunning { self.session.stopRunning() }
            self.recognizer.reset("Camera paused", phase: "paused")
            #if DEBUG && targetEnvironment(simulator)
            self.demoTimer?.cancel(); self.demoTimer = nil
            #endif
            DispatchQueue.main.async { self.ready = false; UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    func setAutomatic(_ enabled: Bool) {
        DispatchQueue.main.async {
            self.automatic = enabled
            UIApplication.shared.isIdleTimerDisabled = enabled || self.ready
        }
        queue.async {
            self.runningAuto = enabled
            self.detector.reset()
            self.publish(enabled ? "Waiting for a still scene" : "Auto capture paused", progress: 0)
        }
    }

    func update(parameters: CaptureParameters, region: CaptureRegion, lockCamera: Bool) {
        queue.async {
            self.recognitionMotion.parameters = parameters
            self.recognitionMotion.parameters.settleDuration = 0.2
            self.recognitionMotion.reset(); self.recognitionStill = false
            self.recognizer.reset()
            self.detector.parameters = parameters
            self.detector.reset()
            self.region = region
            self.locked = lockCamera
            self.applyCameraLock()
        }
    }

    func captureManually() { queue.async { self.capture(trigger: "manual") } }
    func setCorpusSession(_ id: UUID) { queue.async { self.corpusSessionID = id } }

    func completeSave(success: Bool) {
        queue.async {
            self.pending = nil
            self.pendingInvalidatedAt = nil
            self.detector.completeCapture(saved: success, at: self.lastFrameTime)
            if !success { self.runningAuto = false }
            DispatchQueue.main.async {
                self.saving = false
                if !success { self.automatic = false; UIApplication.shared.isIdleTimerDisabled = false }
            }
            self.publish(success ? (self.runningAuto ? "Saved · move the dice for the next photo" : "Photo saved") : "Photo not saved · auto capture paused", progress: 0)
        }
    }

    private func showPermissionDenied() {
        DispatchQueue.main.async {
            self.permissionDenied = true; self.status = "Allow camera access in Settings to capture dice."
        }
    }

    private func configureAndStart() {
        do {
            if !configured {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                session.sessionPreset = .photo
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    throw CameraError.unavailable
                }
                let input = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(input), session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else { throw CameraError.unavailable }
                session.addInput(input); session.addOutput(photoOutput); session.addOutput(videoOutput)
                device = camera
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(self, queue: queue)
                for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
                    if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                    if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
                }
                let dimensions = camera.activeFormat.supportedMaxPhotoDimensions
                    .filter { Int64($0.width) * Int64($0.height) <= 13_000_000 }
                    .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
                if let dimensions { photoOutput.maxPhotoDimensions = dimensions }
                photoOutput.maxPhotoQualityPrioritization = .balanced
                applyCameraLock()
                configured = true
            }
            if !session.isRunning { session.startRunning() }
            detector.reset()
            recognitionRunning = true
            recognitionMotion.reset(); recognitionStill = false
            recognizer.reset()
            DispatchQueue.main.async { self.ready = true; self.permissionDenied = false; UIApplication.shared.isIdleTimerDisabled = true }
            publish("Frame the tray, then start auto capture", progress: 0)
        } catch { fail(error.localizedDescription) }
    }

    private func applyCameraLock() {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = 1
            if device.isFocusModeSupported(locked ? .locked : .continuousAutoFocus) { device.focusMode = locked ? .locked : .continuousAutoFocus }
            if device.isExposureModeSupported(locked ? .locked : .continuousAutoExposure) { device.exposureMode = locked ? .locked : .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(locked ? .locked : .continuousAutoWhiteBalance) { device.whiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance }
        } catch { fail("Camera settings could not be changed: \(error.localizedDescription)") }
    }

    private func pauseForInterruption() {
        queue.async {
            #if DEBUG && targetEnvironment(simulator)
            // The unconfigured preview session can emit AV errors in fixture mode.
            // Its synthetic frame source is independent of AVFoundation.
            if self.demoTimer != nil { return }
            #endif
            self.recognitionRunning = false
            self.recognizer.reset("Camera interrupted", phase: "paused")
            self.recognitionMotion.reset(); self.recognitionStill = false
            self.runningAuto = false; self.detector.reset()
            DispatchQueue.main.async { self.automatic = false; self.ready = false; UIApplication.shared.isIdleTimerDisabled = false }
            self.publish("Camera interrupted · return to the app or tap Retry camera", progress: 0)
        }
    }

    private func process(_ frame: AnalysisFrame, at timestamp: Double) {
        lastFrameTime = timestamp
        lastFrameArrival = ProcessInfo.processInfo.systemUptime
        let recognitionObservation = recognitionMotion.observe(frame, at: timestamp)
        recognitionStill = recognitionObservation.still
        if recognitionObservation.newRoll {
            recognizer.reset(newRoll: true)
        } else if recognitionObservation.invalidated {
            recognizer.reset(onlyIfActive: true)
        }
        guard runningAuto || pending?.trigger == "automatic" else { return }
        let observation = detector.observe(frame, at: timestamp)
        if pending?.trigger == "automatic", !detector.pendingCaptureIsValid, pendingInvalidatedAt == nil { pendingInvalidatedAt = timestamp }
        lastScore = observation.score
        let title: String
        switch observation.phase {
        case .moving: title = "Movement detected"
        case .settling: title = "Settling…"
        case .waitingForMovement: title = "Saved · move the dice for the next photo"
        case .capturing: title = "Capturing…"
        }
        publish(title, progress: observation.progress, score: observation.score)
        if observation.shouldCapture { capture(trigger: "automatic") }
    }

    private func capture(trigger: String) {
        guard pending == nil else { return }
        guard let corpusSessionID else { fail("Start a capture session first."); return }
        pendingInvalidatedAt = nil
        #if DEBUG && targetEnvironment(simulator)
        if demoTimer != nil {
            let image = demoPhoto()
            pending = PendingShot(id: 0, corpusSessionID: corpusSessionID, frameTimestamp: lastFrameTime, trigger: trigger, createdAt: Date(), parameters: detector.parameters, region: region, score: lastScore)
            DispatchQueue.main.async { self.saving = true }
            processPhotoData(image, camera: ["camera": "Simulator fixture", "synthetic": "true"])
            return
        }
        #endif
        guard configured, session.isRunning else { fail("The camera is not ready. Tap Retry camera."); return }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.flashMode = .off
        settings.photoQualityPrioritization = .balanced
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        pending = PendingShot(id: settings.uniqueID, corpusSessionID: corpusSessionID, frameTimestamp: lastFrameTime, trigger: trigger, createdAt: Date(), parameters: detector.parameters, region: region, score: lastScore)
        DispatchQueue.main.async { self.saving = true }
        publish("Capturing…", progress: 1)
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func processPhotoData(_ data: Data, camera: [String: String], photoTimestamp: Double? = nil) {
        guard let shot = pending else { return }
        // Use the actual shutter timestamp, not callback arrival: photo processing can
        // pause video or finish after the player has already moved the dice again.
        let shutter = photoTimestamp ?? shot.frameTimestamp
        let shutterDelay = shutter - shot.frameTimestamp
        let movedBeforeShutter = (pendingInvalidatedAt ?? .infinity) <= shutter
        if shot.trigger == "automatic" && (!shutter.isFinite || movedBeforeShutter || shutterDelay > 0.6 || shutterDelay < -0.05) {
            pending = nil; detector.completeCapture(saved: false, at: lastFrameTime)
            DispatchQueue.main.async { self.saving = false }
            publish("Scene moved · waiting to settle", progress: 0)
            return
        }
        var properties = camera
        properties["triggerFrameTimestampSeconds"] = String(shot.frameTimestamp)
        properties["photoTimestampSeconds"] = String(shutter)
        properties["shutterDelaySeconds"] = String(shutterDelay)
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            properties["encodedWidth"] = String(describing: info[kCGImagePropertyPixelWidth as String] ?? "")
            properties["encodedHeight"] = String(describing: info[kCGImagePropertyPixelHeight as String] ?? "")
            properties["exifOrientation"] = String(describing: info[kCGImagePropertyOrientation as String] ?? 1)
        }
        let thumbnail = Self.thumbnail(data)
        let record = CaptureRecord(capturedAt: shot.createdAt, trigger: shot.trigger, parameters: shot.parameters, region: shot.region, motionScore: shot.score, camera: properties)
        DispatchQueue.main.async {
            guard let callback = self.onPhoto else { self.completeSave(success: false); return }
            callback(data, thumbnail, record, shot.corpusSessionID)
        }
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }

    private func publish(_ text: String, progress: Double, score: Double? = nil) {
        DispatchQueue.main.async {
            self.status = text; self.progress = progress
            if let score { self.motionScore = score }
        }
    }
    private func fail(_ message: String) {
        runningAuto = false
        DispatchQueue.main.async {
            self.automatic = false; self.saving = false; UIApplication.shared.isIdleTimerDisabled = false
            self.status = message; self.onError?(message)
        }
    }

    private enum CameraError: LocalizedError {
        case unavailable
        var errorDescription: String? { "A rear camera is unavailable. Use a physical iPhone and tap Retry camera." }
    }

    #if DEBUG && targetEnvironment(simulator)
    private var demoTimer: DispatchSourceTimer?
    private var demoArrangement = 0
    private var demoMotionTicks = 0
    private var demoTick = 0
    func nextDemoArrangement() { queue.async {
        self.demoArrangement += 1
        self.demoMotionTicks = ProcessInfo.processInfo.arguments.contains("-recognition-fast-roll-demo") ? 2 : 16
    } }
    private func startDemo() {
        queue.async {
            guard self.demoTimer == nil else { return }
            self.recognitionRunning = true
            self.recognitionMotion.reset(); self.recognitionStill = false
            self.recognizer.reset()
            DispatchQueue.main.async { self.isDemo = true; self.ready = true; UIApplication.shared.isIdleTimerDisabled = true }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 0.05)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.demoTick += 1
                if self.demoMotionTicks > 0 { self.demoMotionTicks -= 1 }
                let noiseDemo = ProcessInfo.processInfo.arguments.contains("-recognition-noise-demo") && self.demoTick > 30
                // Debug-only regression trace: unchanged photo, exposure drift,
                // isolated spatial spikes and a 700ms camera gap.
                if noiseDemo && self.demoMotionTicks == 0 && self.demoTick % 80 >= 60 && self.demoTick % 80 < 74 { return }
                let image = self.demoPhoto()
                DispatchQueue.main.async { self.demoImage = UIImage(data: image) }
                var pixels = [UInt8](repeating: 22, count: 96 * 128)
                let offset = self.demoMotionTicks > 0 ? (self.demoTick % 2) * 20 : 0
                let x = 20 + (self.demoArrangement % 3) * 10 + offset
                for y in 45..<61 { for xx in x..<min(x + 16, 96) { pixels[y * 96 + xx] = 220 } }
                if noiseDemo {
                    let brightness = (self.demoTick / 10) % 10
                    pixels = pixels.map { UInt8(Int($0) + brightness) }
                    if self.demoMotionTicks == 0 && self.demoTick % 20 == 0 {
                        for y in 12..<24 { for xx in 12..<24 { pixels[y * 96 + xx] = 220 } }
                    }
                }
                let time = ProcessInfo.processInfo.systemUptime
                self.process(AnalysisFrame(width: 96, height: 128, pixels: pixels), at: time)
                if let ci = CIImage(data: image) { self.recognizer.submit(ci, region: self.region, still: self.recognitionStill, timestamp: time) }
            }
            self.demoTimer = timer; timer.resume()
            self.publish("Simulator fixture · frame the tray", progress: 0)
        }
    }
    private func demoPhoto() -> Data {
        // Local-only QA: inject an EXIF-normalized held-out image into the simulator
        // Documents directory. Never included in a release or a corpus export.
        let fixture = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("recognition-qa.jpg")
        if let data = try? Data(contentsOf: fixture) { return data }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 768, height: 1024))
        return renderer.jpegData(withCompressionQuality: 0.95) { context in
            UIColor(red: 0.06, green: 0.08, blue: 0.08, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 768, height: 1024))
            UIColor(red: 0.67, green: 0.50, blue: 0.29, alpha: 1).setStroke()
            let border = UIBezierPath(roundedRect: CGRect(x: 28, y: 28, width: 712, height: 968), cornerRadius: 20); border.lineWidth = 20; border.stroke()
            for i in 0..<5 {
                let x = CGFloat(150 + (i % 2) * 260 + (demoArrangement % 3) * 10)
                let y = CGFloat(170 + (i / 2) * 260)
                UIColor(white: 0.95, alpha: 1).setFill(); UIBezierPath(roundedRect: CGRect(x: x, y: y, width: 125, height: 125), cornerRadius: 18).fill()
                UIColor.black.setFill()
                for point in [CGPoint(x: x + 32, y: y + 32), CGPoint(x: x + 92, y: y + 92), CGPoint(x: x + 62, y: y + 62)] {
                    UIBezierPath(ovalIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)).fill()
                }
            }
        }
    }
    #endif
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recognitionRunning else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let source = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let outWidth = 96, outHeight = 128
        let cropWidth = max(0.1, 1 - region.left - region.right), cropHeight = max(0.1, 1 - region.top - region.bottom)
        var pixels = [UInt8](); pixels.reserveCapacity(outWidth * outHeight)
        for y in 0..<outHeight {
            let sy = min(height - 2, max(0, Int((region.top + (Double(y) + 0.5) / Double(outHeight) * cropHeight) * Double(height))))
            for x in 0..<outWidth {
                let sx = min(width - 2, max(0, Int((region.left + (Double(x) + 0.5) / Double(outWidth) * cropWidth) * Double(width))))
                let sum = Int(source[sy * stride + sx]) + Int(source[sy * stride + sx + 1]) + Int(source[(sy + 1) * stride + sx]) + Int(source[(sy + 1) * stride + sx + 1])
                pixels.append(UInt8(sum / 4))
            }
        }
        if timestamp - lastAnalysisTime >= 0.045 {
            lastAnalysisTime = timestamp
            process(.init(width: outWidth, height: outHeight, pixels: pixels), at: timestamp)
        }
        recognizer.submit(CIImage(cvPixelBuffer: buffer), region: region, still: recognitionStill, timestamp: timestamp)
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        queue.async {
            guard self.pending?.id == photo.resolvedSettings.uniqueID else { return }
            if let error { self.pending = nil; self.detector.completeCapture(saved: false, at: self.lastFrameTime); self.fail(error.localizedDescription); return }
            guard let data = photo.fileDataRepresentation() else { self.pending = nil; self.fail("The camera returned no image data."); return }
            var camera = ["camera": self.device?.localizedName ?? "Rear wide camera", "lens": "rear wide · 1×", "focusExposureWhiteBalanceLocked": String(self.locked)]
            if let device = self.device {
                camera["iso"] = String(device.iso); camera["exposureSeconds"] = String(device.exposureDuration.seconds)
                camera["lensPosition"] = String(device.lensPosition)
            }
            self.processPhotoData(data, camera: camera, photoTimestamp: photo.timestamp.seconds)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard let error else { return }
        queue.async {
            guard self.pending?.id == resolvedSettings.uniqueID else { return }
            self.pending = nil; self.detector.completeCapture(saved: false, at: self.lastFrameTime); self.fail(error.localizedDescription)
        }
    }
}
