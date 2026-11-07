import XCTest
import CoreGraphics
@testable import DiceCaptureCore

final class RollUploadValidationTests: XCTestCase {
    func face(_ confidence: Double, value: Int = 4, x: Double = 0.2) -> RollFace {
        RollFace(value: value, confidence: confidence, box: CGRect(x: x, y: 0.2, width: 0.1, height: 0.1))
    }
    func testActualPhoneOverflowBecomesValidWithoutChangingValueOrGeometry() throws {
        let original = face(1.0000001192092896)
        let repaired = try XCTUnwrap(RollUploadValidation.faces([original]).first)
        XCTAssertEqual(repaired.confidence, 1)
        XCTAssertEqual(repaired.value, original.value); XCTAssertEqual(repaired.box, original.box)
        XCTAssertTrue(RollUploadValidation.hasRecoverableOvershoot([original]))
    }
    func testRejectNonFiniteScoresAndIdentifyInvalidGeometry() {
        for score in [Double.nan, .infinity, -.infinity] { XCTAssertThrowsError(try RollUploadValidation.faces([face(score)])) }
        XCTAssertThrowsError(try RollUploadValidation.faces([face(0.9, x: -0.1)])) { error in
            XCTAssertTrue(error.localizedDescription.contains("dice[0].box"))
        }
        XCTAssertThrowsError(try RollUploadValidation.faces([face(0.9, value: 7)]))
    }
    func testAutomaticRecoveryIsRestrictedToKnownTinyOvershoot() {
        XCTAssertFalse(RollUploadValidation.hasRecoverableOvershoot([face(1.1)]))
        XCTAssertFalse(RollUploadValidation.hasRecoverableOvershoot([face(.nan)]))
        XCTAssertFalse(RollUploadValidation.hasRecoverableOvershoot([face(1)]))
        XCTAssertEqual(try RollUploadValidation.faces([face(-0.001)])[0].confidence, 0)
    }
}
