import XCTest
@testable import DiceCaptureCore

final class UploadQuarantineTests: XCTestCase {
    func testRules401IsPermanentOnlyAfterAuthRefreshAndExpiredTokensStayRetryable() {
        XCTAssertFalse(UploadResponsePolicy.isPermanentRejection(status: 401, message: "Permission denied", authenticationRefreshed: false))
        XCTAssertTrue(UploadResponsePolicy.isPermanentRejection(status: 401, message: "Permission denied", authenticationRefreshed: true))
        XCTAssertFalse(UploadResponsePolicy.isPermanentRejection(status: 401, message: "Auth token is expired", authenticationRefreshed: true))
        XCTAssertFalse(UploadResponsePolicy.isPermanentRejection(status: 503, message: "Unavailable", authenticationRefreshed: true))
        XCTAssertTrue(UploadResponsePolicy.isPermanentRejection(status: 403, message: "Permission denied", authenticationRefreshed: false))
    }
    enum Failure: Error, Equatable { case rejected, offline }
    struct Payload: Codable { let id: String }
    actor Sender {
        var delivered: [String] = []
        func send(_ file: URL) throws {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: file))
            if payload.id == "rejected" { throw Failure.rejected }
            if payload.id == "offline" { throw Failure.offline }
            delivered.append(payload.id)
            try FileManager.default.removeItem(at: file)
        }
    }
    private func pending(_ name: String, _ contents: String, in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(name + ".json")
        try Data(contents.utf8).write(to: file); return file
    }
    func testRejectedAndUnreadableFilesDoNotBlockUUIDSuffixOrMetrics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = root.appendingPathComponent("Pending")
        let files = try [pending("0-first", "{\"id\":\"first\"}", in: queue),
                         pending("A-rejected", "{\"id\":\"rejected\"}", in: queue),
                         pending("B-unreadable", "not json", in: queue),
                         pending("F-last", "{\"id\":\"last\"}", in: queue)]
        let saved = try Data(contentsOf: files[1])
        let held = UploadQuarantine(root: root.appendingPathComponent("Held")); let sender = Sender()
        try await drainUploadFiles(files, enabled: { true }, deliver: { try await sender.send($0) },
            permanent: { $0 is DecodingError || ($0 as? Failure) == .rejected },
            hold: { try held.hold($0, kind: "rolls", reason: String(describing: $1)) })
        let delivered = await sender.delivered
        XCTAssertEqual(delivered, ["first", "last"]); XCTAssertEqual(held.status().count, 2)
        let metric = try pending("metric", "{\"id\":\"metric\"}", in: queue)
        try await drainUploadFiles([metric], enabled: { true }, deliver: { try await sender.send($0) }, permanent: { _ in false }, hold: { _, _ in XCTFail() })
        let all = await sender.delivered; XCTAssertEqual(all, ["first", "last", "metric"])
        try held.retry { _ in queue }
        XCTAssertEqual(try Data(contentsOf: files[1]), saved)
        XCTAssertEqual(try String(contentsOf: files[2], encoding: .utf8), "not json")
        XCTAssertEqual(held.status().count, 0)
    }
    func testTransientFailurePreservesPendingDataAndNeverQuarantinesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try pending("offline", "{\"id\":\"offline\"}", in: root)
        let sender = Sender()
        do {
            try await drainUploadFiles([file], enabled: { true }, deliver: { try await sender.send($0) }, permanent: { _ in false }, hold: { _, _ in XCTFail() })
            XCTFail("Network error was hidden")
        } catch { XCTAssertEqual(error as? Failure, .offline) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testStoppingSharingDoesNotSendOrMoveFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try pending("saved", "original", in: root)
        try await drainUploadFiles([file], enabled: { false }, deliver: { _ in XCTFail() }, permanent: { _ in true }, hold: { _, _ in XCTFail() })
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }
}
