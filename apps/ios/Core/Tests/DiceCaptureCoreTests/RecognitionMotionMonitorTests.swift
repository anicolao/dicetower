import XCTest
@testable import DiceCaptureCore

final class RecognitionMotionMonitorTests: XCTestCase {
    private func frame(_ value: UInt8 = 30, patch: Int? = nil) -> AnalysisFrame {
        var pixels = [UInt8](repeating: value, count: 96 * 128)
        if let patch { for y in 24..<36 { for x in patch..<patch + 12 { pixels[y * 96 + x] = 220 } } }
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
            if i < 3 { XCTAssertFalse(result.newRoll) }
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
}
