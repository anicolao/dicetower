import XCTest
import CoreGraphics
@testable import DiceCaptureCore
final class RollEventGateTests: XCTestCase {
    private func face(_ value: Int, x: Double = 0.2) -> RollFace {
        RollFace(value: value, confidence: 0.9, box: CGRect(x: x, y: 0.2, width: 0.1, height: 0.1))
    }
    func testUnchangedReadingAndJitterDoNotDuplicate() {
        var gate = RollEventGate()
        XCTAssertEqual(gate.accept([face(3)])?.kind, "roll")
        XCTAssertNil(gate.accept([face(3, x: 0.21)]))
        XCTAssertNil(gate.accept([face(3)]))
    }
    func testSameValuesAfterMotionAreNewRoll() {
        var gate = RollEventGate()
        let first = gate.accept([face(3)])!
        gate.moved()
        let second = gate.accept([face(3)])!
        XCTAssertEqual(second.kind, "roll")
        XCTAssertNotEqual(first.rollID, second.rollID)
    }
    func testCorrectionKeepsRollIDAndEmptyTrayIsRepresented() {
        var gate = RollEventGate()
        let first = gate.accept([face(3)])!
        let correction = gate.accept([face(4)])!
        XCTAssertEqual(first.rollID, correction.rollID)
        XCTAssertEqual(correction.kind, "recognitionChanged")
        XCTAssertNil(gate.accept([face(4)]))
        gate.moved()
        XCTAssertEqual(gate.accept([])?.kind, "roll")
        XCTAssertNil(gate.accept([]))
    }
    func testXOrderDoesNotInventCorrections() {
        var gate = RollEventGate()
        _ = gate.accept([face(3),face(4)])
        XCTAssertNil(gate.accept([face(4),face(3)]))
    }
}
