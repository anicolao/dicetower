import XCTest
@testable import DiceCaptureCore

final class RecognitionMotionMonitorTests: XCTestCase {
    private func frame(_ value: UInt8 = 30, patch: Int? = nil, patchValue: UInt8 = 220) -> AnalysisFrame {
        var pixels = [UInt8](repeating: value, count: 96 * 128)
        if let patch { for y in 24..<36 { for x in patch..<patch + 12 { pixels[y * 96 + x] = patchValue } } }
        return .init(width: 96, height: 128, pixels: pixels)
    }
    private func settled() -> RecognitionMotionMonitor {
        var monitor = RecognitionMotionMonitor()
        for i in 0...4 { _ = monitor.observe(frame(), at: Double(i) * 0.05) }
        return monitor
    }
    func testInitialSettlementStillTakesOnly200ms() {
        var monitor = RecognitionMotionMonitor()
        for time in [0.0, 0.05, 0.1, 0.15, 0.199] { XCTAssertFalse(monitor.observe(frame(), at: time).still) }
        XCTAssertTrue(monitor.observe(frame(), at: 0.2).still)
    }
    func testOneFrameDisturbanceInvalidatesReadingButDoesNotRearm() {
        var monitor = settled()
        let spike = monitor.observe(frame(patch: 12), at: 0.25)
        XCTAssertTrue(spike.invalidated); XCTAssertFalse(spike.still); XCTAssertFalse(spike.newRoll)
        for i in 6...20 { XCTAssertFalse(monitor.observe(frame(), at: Double(i) * 0.05).newRoll) }
        XCTAssertTrue(monitor.observe(frame(), at: 1.05).still)
    }
    func testRepeatedIsolatedSpikesCannotAccumulateIntoMovement() {
        var monitor = settled()
        for i in 5...100 {
            XCTAssertFalse(monitor.observe(frame(patch: i % 10 == 0 ? 12 : nil), at: Double(i) * 0.05).newRoll)
        }
    }
    func testUniformFlickerAndSlowExposureDriftNeverRearm() {
        var monitor = settled()
        for i in 5...50 {
            XCTAssertFalse(monitor.observe(frame(i.isMultiple(of: 2) ? 40 : 90), at: Double(i) * 0.05).newRoll)
        }
        for i in 51...150 {
            XCTAssertFalse(monitor.observe(frame(UInt8(i)), at: Double(i) * 0.05).newRoll)
        }
    }
    func testFrameGapDoesNotInventANewRollAndBreaksMovementEvidence() {
        var monitor = settled()
        _ = monitor.observe(frame(patch: 12), at: 0.25)
        let gap = monitor.observe(frame(patch: 24), at: 2)
        XCTAssertTrue(gap.invalidated); XCTAssertFalse(gap.newRoll)
        XCTAssertFalse(monitor.observe(frame(patch: 36), at: 2.05).newRoll)
        for i in 1...10 { XCTAssertFalse(monitor.observe(frame(), at: 2.05 + Double(i) * 0.05).newRoll) }
    }
    func testSustainedMovementRearmsOnceThenSettlesForANewIdenticalRoll() {
        var monitor = settled()
        var newRolls = 0
        for i in 0..<8 {
            let result = monitor.observe(frame(patch: 12 + (i % 5) * 12), at: 0.25 + Double(i) * 0.05)
            if i == 0 { XCTAssertFalse(result.newRoll) }
            if result.newRoll { newRolls += 1 }
        }
        XCTAssertEqual(newRolls, 1)
        for i in 0...4 { _ = monitor.observe(frame(), at: 0.65 + Double(i) * 0.05) }
        XCTAssertTrue(monitor.observe(frame(), at: 0.9).still)
        for i in 0..<6 {
            if monitor.observe(frame(patch: 12 + i * 12), at: 1 + Double(i) * 0.05).newRoll { newRolls += 1 }
        }
        XCTAssertEqual(newRolls, 2)
    }
    func testFastRollAlreadyStoppedAtSecondObservationStillRearms() {
        var monitor = settled()
        XCTAssertFalse(monitor.observe(frame(patch: 24), at: 0.25).newRoll)
        // No further movement: the dice are already in their new positions.
        XCTAssertTrue(monitor.observe(frame(patch: 24), at: 0.30).newRoll)
        for i in 7...30 { XCTAssertFalse(monitor.observe(frame(patch: 24), at: Double(i) * 0.05).newRoll) }
        XCTAssertTrue(monitor.observe(frame(patch: 24), at: 1.55).still)
    }
    func testQuietFrameDuringRollDoesNotEraseEvidenceOfChangedScene() {
        var monitor = settled()
        XCTAssertFalse(monitor.observe(frame(patch: 12), at: 0.25).newRoll)
        XCTAssertTrue(monitor.observe(frame(patch: 12), at: 0.30).newRoll)
        XCTAssertFalse(monitor.observe(frame(patch: 36), at: 0.35).newRoll)
    }
    func testReferenceAndSettlingAnchorDifferenceCannotRepeatedlyRearm() {
        var monitor = RecognitionMotionMonitor()
        for i in 0...4 { _ = monitor.observe(frame(patch: 12, patchValue: UInt8(30 + min(i, 3))), at: Double(i) * 0.05) }
        XCTAssertFalse(monitor.observe(frame(patch: 12, patchValue: 26), at: 0.25).newRoll)
        XCTAssertFalse(monitor.observe(frame(patch: 12, patchValue: 23), at: 0.30).newRoll)
        XCTAssertTrue(monitor.observe(frame(patch: 12, patchValue: 23), at: 0.35).newRoll)
        for i in 8...40 { XCTAssertFalse(monitor.observe(frame(patch: 12, patchValue: 23), at: Double(i) * 0.05).newRoll) }
    }
}
