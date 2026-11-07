import XCTest
import CoreGraphics
@testable import DiceCaptureCore
final class RecognitionCycleTests: XCTestCase {
    private func face(_ n: Int, x: Double = 0.2) -> RollFace { .init(value: n, confidence: 0.9, box: CGRect(x: x, y: 0.2, width: 0.1, height: 0.1)) }
    func testTwoStillInferencesThenNoWorkUntilMotionReset() {
        var c = RecognitionCycle(); c.started(at: 0)
        XCTAssertFalse(c.completed(faces: [face(4)], still: true, inferenceMs: 12, processingMs: 20, at: 0.02))
        XCTAssertEqual(c.agreementCount, 1); XCTAssertFalse(c.canStart(at: 0.049)); XCTAssertTrue(c.canStart(at: 0.05))
        c.started(at: 0.05)
        XCTAssertTrue(c.completed(faces: [face(4)], still: true, inferenceMs: 12, processingMs: 20, at: 0.07))
        XCTAssertFalse(c.canStart(at: 100)); XCTAssertEqual(c.inferenceCount, 2)
        c.reset(); XCTAssertTrue(c.canStart(at: 100)); XCTAssertEqual(c.inferenceCount, 2)
    }
    func testEMAAndRoundUpIn50msSteps() {
        var c = RecognitionCycle(); c.started(at: 0)
        _ = c.completed(faces: [], still: false, inferenceMs: 51, processingMs: 70, at: 0.07)
        XCTAssertEqual(c.intervalMs, 100); XCTAssertEqual(c.emaInferenceMs, 51)
        c.started(at: 0.1)
        _ = c.completed(faces: [], still: false, inferenceMs: 21, processingMs: 30, at: 0.13)
        XCTAssertEqual(c.emaInferenceMs, 45, accuracy: 0.000001); XCTAssertEqual(c.intervalMs, 50)
        XCTAssertEqual(c.nextStart, 0.15, accuracy: 0.000001)
    }
    func testOverrunNeverSchedulesBeforeCompletionAndMismatchRestartsAgreement() {
        var c = RecognitionCycle(); c.started(at: 0)
        _ = c.completed(faces: [face(3)], still: true, inferenceMs: 40, processingMs: 125, at: 0.125)
        XCTAssertEqual(c.nextStart, 0.15, accuracy: 0.000001)
        c.started(at: 0.15)
        XCTAssertFalse(c.completed(faces: [face(4)], still: true, inferenceMs: 40, processingMs: 60, at: 0.21))
        XCTAssertEqual(c.agreementCount, 1)
        c.started(at: 0.25)
        XCTAssertFalse(c.completed(faces: [face(4)], still: false, inferenceMs: 40, processingMs: 60, at: 0.31))
        XCTAssertEqual(c.agreementCount, 0)
    }
    func testReorderedDiceCanAgreeButPositionAndValueChangesCannot() {
        XCTAssertTrue(RecognitionCycle.matches([face(3),face(4,x:0.7)],[face(4,x:0.7),face(3)]))
        XCTAssertFalse(RecognitionCycle.matches([face(3)],[face(4)]))
        XCTAssertFalse(RecognitionCycle.matches([face(3)],[face(3,x:0.3)]))
    }
    func testInvalidatedInferenceUpdatesTimingButCannotSettle() {
        var c = RecognitionCycle(); c.started(at: 0)
        c.discarded(inferenceMs: 80, processingMs: 90, at: 0.09)
        XCTAssertEqual(c.inferenceCount, 1); XCTAssertEqual(c.agreementCount, 0); XCTAssertFalse(c.quiescent)
    }
}
