import XCTest
@testable import DiceCaptureCore

final class QuiescenceDetectorTests: XCTestCase {
    func frame(_ value: UInt8) -> AnalysisFrame { .init(width: 48, height: 48, pixels: .init(repeating: value, count: 48 * 48)) }
    func settle(_ detector: inout QuiescenceDetector, _ frame: AnalysisFrame, from: Double) -> [MotionObservation] {
        (0..<20).map { detector.observe(frame, at: from + Double($0) * 0.1) }
    }

    func testOneCaptureForAStationarySceneThenNoDuplicates() {
        var detector = QuiescenceDetector()
        let initial = settle(&detector, frame(30), from: 0)
        XCTAssertEqual(initial.filter(\.shouldCapture).count, 1)
        detector.completeCapture(saved: true, at: 1.9)
        XCTAssertFalse(settle(&detector, frame(30), from: 2).contains(where: \.shouldCapture))
        XCTAssertFalse(settle(&detector, frame(30), from: 4).contains(where: \.shouldCapture))
    }

    func testNewMovementRearmsAndWaitsForSettling() {
        var detector = QuiescenceDetector()
        _ = settle(&detector, frame(30), from: 0)
        detector.completeCapture(saved: true, at: 1.9)
        _ = settle(&detector, frame(30), from: 2)
        for i in 0..<10 {
            XCTAssertFalse(detector.observe(frame(i.isMultiple(of: 2) ? 180 : 30), at: 4 + Double(i) * 0.1).shouldCapture)
        }
        XCTAssertEqual(settle(&detector, frame(90), from: 5).filter(\.shouldCapture).count, 1)
    }

    func testContinuousMotionNeverCaptures() {
        var detector = QuiescenceDetector()
        for i in 0..<100 {
            XCTAssertFalse(detector.observe(frame(i.isMultiple(of: 2) ? 20 : 180), at: Double(i) * 0.1).shouldCapture)
        }
    }

    func testCameraGapRestartsTheSettlingWindow() {
        var detector = QuiescenceDetector()
        _ = detector.observe(frame(30), at: 0)
        _ = detector.observe(frame(30), at: 0.1)
        XCTAssertFalse(detector.observe(frame(30), at: 10).shouldCapture)
        XCTAssertFalse(detector.observe(frame(30), at: 10.1).shouldCapture)
        XCTAssertEqual(settle(&detector, frame(30), from: 10.2).filter(\.shouldCapture).count, 1)
    }

    func testMovementDuringPhotoInvalidatesIt() {
        var detector = QuiescenceDetector()
        _ = settle(&detector, frame(30), from: 0)
        XCTAssertTrue(detector.pendingCaptureIsValid)
        _ = detector.observe(frame(220), at: 2)
        XCTAssertFalse(detector.pendingCaptureIsValid)
        detector.completeCapture(saved: false, at: 2)
        XCTAssertEqual(settle(&detector, frame(220), from: 2.1).filter(\.shouldCapture).count, 1)
    }

    func testSmallLocalMovementIsVisibleAndSensorNoiseIsQuiet() {
        let background = frame(20)
        var pixels = background.pixels
        for y in 12..<18 { for x in 12..<18 { pixels[y * 48 + x] = 220 } }
        let die = AnalysisFrame(width: 48, height: 48, pixels: pixels)
        XCTAssertGreaterThan(die.difference(from: background), CaptureParameters().motionThreshold)
        XCTAssertLessThan(frame(21).difference(from: background), CaptureParameters().motionThreshold)
    }

    func testSlowDriftCannotSatisfySettling() {
        var detector = QuiescenceDetector(parameters: .init(settleDuration: 1.2, motionThreshold: 0.012))
        for i in 0..<60 {
            XCTAssertFalse(detector.observe(frame(UInt8(30 + i)), at: Double(i) * 0.1).shouldCapture)
        }
    }

    func testFailedSaveRetriesWithoutAnotherRoll() {
        var detector = QuiescenceDetector()
        _ = settle(&detector, frame(30), from: 0)
        detector.completeCapture(saved: false, at: 2)
        XCTAssertEqual(settle(&detector, frame(30), from: 2.1).filter(\.shouldCapture).count, 1)
    }
}
