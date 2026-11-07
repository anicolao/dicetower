import XCTest
import CoreGraphics
@testable import DiceCaptureCore

final class ReportedRollFilterTests: XCTestCase {
    private func face(_ value: Int, _ x: Double = 0.2, confidence: Double = 0.9) -> RollFace {
        RollFace(value: value, confidence: confidence, box: CGRect(x: x, y: 0.2, width: 0.1, height: 0.1))
    }
    func testDuplicateAfterRearmingIgnoresOrderConfidenceAndSmallJitter() {
        var filter = ReportedRollFilter()
        XCTAssertNil(filter.duplicateEventID(for: [face(3)]))
        filter.record([face(3), face(4, 0.6)], eventID: "first")
        XCTAssertEqual(filter.duplicateEventID(for: [face(4, 0.605, confidence: 0.8), face(3, 0.205)]), "first")
    }
    func testSameValuesAtNewPositionsAndChangedValuesOrCountAreNotDuplicates() {
        var filter = ReportedRollFilter(); filter.record([face(3)], eventID: "first")
        XCTAssertNil(filter.duplicateEventID(for: [face(3, 0.22)]))
        XCTAssertNil(filter.duplicateEventID(for: [face(4)]))
        XCTAssertNil(filter.duplicateEventID(for: []))
    }
    func testDiscardedReadingsDoNotMoveTheReference() {
        var filter = ReportedRollFilter(); filter.record([face(3)], eventID: "first")
        XCTAssertEqual(filter.duplicateEventID(for: [face(3, 0.206)]), "first")
        XCTAssertNil(filter.duplicateEventID(for: [face(3, 0.212)]))
        filter.record([face(3, 0.212)], eventID: "second")
        XCTAssertEqual(filter.duplicateEventID(for: [face(3, 0.212)]), "second")
    }
    func testEmptyTrayOnlyMatchesAnAlreadyReportedEmptyTray() {
        var filter = ReportedRollFilter(); XCTAssertNil(filter.duplicateEventID(for: []))
        filter.record([], eventID: "empty"); XCTAssertEqual(filter.duplicateEventID(for: []), "empty")
        XCTAssertNil(filter.duplicateEventID(for: [face(1)]))
    }
}
