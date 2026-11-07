import Foundation
import CryptoKit

public struct CaptureRegion: Codable, Equatable, Sendable {
    public var left: Double = 0.05
    public var top: Double = 0.05
    public var right: Double = 0.05
    public var bottom: Double = 0.05
    public init(left: Double = 0.05, top: Double = 0.05, right: Double = 0.05, bottom: Double = 0.05) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
}

public struct CaptureSession: Codable, Identifiable, Sendable, Equatable {
    public var schemaVersion = 1
    public let id: UUID
    public let createdAt: Date
    public let notes: String
    public let device: String
    public let operatingSystem: String
    public let appVersion: String
    public let labelingStatus: String
    public init(id: UUID = UUID(), createdAt: Date = Date(), notes: String, device: String, operatingSystem: String, appVersion: String) {
        self.id = id; self.createdAt = createdAt; self.notes = notes; self.device = device
        self.operatingSystem = operatingSystem; self.appVersion = appVersion; self.labelingStatus = "unlabeled"
    }
}

public struct CaptureRecord: Codable, Identifiable, Sendable, Equatable {
    public var schemaVersion = 1
    public let id: UUID
    public let capturedAt: Date
    public let trigger: String
    public let parameters: CaptureParameters
    public let region: CaptureRegion
    public let motionScore: Double
    public let camera: [String: String]
    public var sha256: String
    public var imageFilename = "image.jpg"
    public var labelingStatus = "unlabeled"
    public init(id: UUID = UUID(), capturedAt: Date = Date(), trigger: String, parameters: CaptureParameters,
                region: CaptureRegion, motionScore: Double, camera: [String: String], sha256: String = "") {
        self.id = id; self.capturedAt = capturedAt; self.trigger = trigger; self.parameters = parameters
        self.region = region; self.motionScore = motionScore; self.camera = camera; self.sha256 = sha256
    }
}

public enum CorpusStoreError: LocalizedError {
    case missingSession, duplicateCapture, noImages, exportFailed
    public var errorDescription: String? {
        switch self {
        case .missingSession: "The capture session could not be found. Start a new session."
        case .duplicateCapture: "This photo has already been saved."
        case .noImages: "Capture a photo before exporting this session."
        case .exportFailed: "The session ZIP could not be created. Your original photos are still saved."
        }
    }
}

/// Serial, atomic publication of image/metadata pairs. No model-produced labels.
public actor CorpusStore {
    public nonisolated let root: URL
    public init(root: URL) { self.root = root }

    private var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer(); try container.encode(formatter.string(from: date))
        }
        return e
    }
    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer(); let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: text) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid capture date") }
            return date
        }
        return d
    }
    public nonisolated func sessionURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public nonisolated func captureURL(_ id: UUID, session: UUID) -> URL {
        sessionURL(session).appendingPathComponent("captures", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }
    public func sessions() throws -> [CaptureSession] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .compactMap { try? decoder.decode(CaptureSession.self, from: Data(contentsOf: $0.appendingPathComponent("session.json"))) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    public func create(_ session: CaptureSession) throws {
        let directory = sessionURL(session.id)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("captures"), withIntermediateDirectories: true)
        try encoder.encode(session).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
    public func records(in session: UUID) throws -> [CaptureRecord] {
        let directory = sessionURL(session).appendingPathComponent("captures")
        guard FileManager.default.fileExists(atPath: directory.path) else { throw CorpusStoreError.missingSession }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .compactMap { try? decoder.decode(CaptureRecord.self, from: Data(contentsOf: $0.appendingPathComponent("capture.json"))) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }
    public func save(image: Data, thumbnail: Data?, record: CaptureRecord, in session: UUID) throws -> CaptureRecord {
        guard FileManager.default.fileExists(atPath: sessionURL(session).appendingPathComponent("session.json").path) else { throw CorpusStoreError.missingSession }
        let destination = captureURL(record.id, session: session)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CorpusStoreError.duplicateCapture }
        let pending = root.deletingLastPathComponent().appendingPathComponent("PendingCaptures", isDirectory: true).appendingPathComponent(record.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        var published = record
        published.sha256 = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        try image.write(to: pending.appendingPathComponent("image.jpg"), options: .atomic)
        try thumbnail?.write(to: pending.appendingPathComponent("thumbnail.jpg"), options: .atomic)
        try encoder.encode(published).write(to: pending.appendingPathComponent("capture.json"), options: .atomic)
        // The complete capture directory appears in the corpus in one rename.
        // A failed write remains outside sessions for recovery and is never exported.
        try FileManager.default.moveItem(at: pending, to: destination)
        return published
    }
    public func export(_ session: UUID, to destination: URL) throws -> URL {
        guard try !records(in: session).isEmpty else { throw CorpusStoreError.noImages }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var copyError: Error?
        let manager = FileManager.default
        NSFileCoordinator().coordinate(readingItemAt: sessionURL(session), options: .forUploading, error: &coordinationError) { archive in
            do { try manager.copyItem(at: archive, to: destination) } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard manager.fileExists(atPath: destination.path) else { throw CorpusStoreError.exportFailed }
        return destination
    }
}
