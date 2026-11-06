import XCTest
import CryptoKit
@testable import DiceCaptureCore

final class CorpusStoreTests: XCTestCase {
    func testSavePublishesOriginalHashMetadataAndSurvivesReopening() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Sessions")
        let store = CorpusStore(root: root)
        let session = CaptureSession(notes: "White d6; overhead; diffuse light", device: "test", operatingSystem: "test", appVersion: "0.1")
        try await store.create(session)
        let data = Data("original image bytes".utf8)
        let record = CaptureRecord(trigger: "automatic", parameters: .init(), region: .init(), motionScore: 0, camera: [:])
        let saved = try await store.save(image: data, thumbnail: nil, record: record, in: session.id)
        XCTAssertEqual(saved.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try Data(contentsOf: store.captureURL(record.id, session: session.id).appendingPathComponent("image.jpg")), data)
        let reopened = CorpusStore(root: root)
        let records = try await reopened.records(in: session.id)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, saved.id)
        XCTAssertEqual(records.first?.sha256, saved.sha256)
        XCTAssertEqual(records.first?.trigger, "automatic")
        XCTAssertEqual(try XCTUnwrap(records.first).capturedAt.timeIntervalSince1970, saved.capturedAt.timeIntervalSince1970, accuracy: 0.001)
        let sessions = try await reopened.sessions()
        XCTAssertEqual(sessions.count, 1)
        do { _ = try await store.save(image: Data("replacement".utf8), thumbnail: nil, record: record, in: session.id); XCTFail("Overwrote capture") }
        catch { XCTAssertTrue(error is CorpusStoreError) }
        XCTAssertEqual(try Data(contentsOf: store.captureURL(record.id, session: session.id).appendingPathComponent("image.jpg")), data)
    }

    func testExportIsAZipAndHasTheCapturedImage() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = CorpusStore(root: base.appendingPathComponent("Sessions"))
        let session = CaptureSession(notes: "", device: "test", operatingSystem: "test", appVersion: "0.1")
        try await store.create(session)
        let record = CaptureRecord(trigger: "manual", parameters: .init(), region: .init(), motionScore: 0, camera: [:])
        _ = try await store.save(image: Data([1, 2, 3]), thumbnail: nil, record: record, in: session.id)
        let archive = try await store.export(session.id, to: base.appendingPathComponent("export.zip"))
        let bytes = try Data(contentsOf: archive)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        #if os(macOS)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        let listing = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(listing.contains("session.json"))
        XCTAssertTrue(listing.contains("image.jpg"))
        XCTAssertTrue(listing.contains("capture.json"))
        #endif
    }
}
