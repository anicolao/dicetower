import XCTest
import CoreGraphics
@testable import DiceCaptureCore

final class RecognitionGeometryTests: XCTestCase {
    func testPortraitLetterboxReturnsCropAndFlipsVisionY() {
        let geometry = RecognitionGeometry(imageSize: CGSize(width: 900, height: 1200),
            region: CaptureRegion(left: 10.0/900, top: 0.1, right: 150.0/900, bottom: 0.1))
        XCTAssertEqual(geometry.crop, CGRect(x: 10, y: 120, width: 740, height: 960))
        let input = CGRect(x: geometry.padding.x / 416, y: 0, width: 321.0/416, height: 1)
        let box = geometry.cameraBox(fromVision: input)!
        XCTAssertEqual(box.minX, 10.0/900, accuracy: 0.000001)
        XCTAssertEqual(box.minY, 0.1, accuracy: 0.000001)
        XCTAssertEqual(box.width, 740.0/900, accuracy: 0.000001)
        XCTAssertEqual(box.height, 0.8, accuracy: 0.000001)
        let upper = geometry.cameraBox(fromVision: CGRect(x: 0.4, y: 0.7, width: 0.1, height: 0.1))!
        let lower = geometry.cameraBox(fromVision: CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.1))!
        XCTAssertLessThan(upper.minY, lower.minY)
    }
    func testPaddingRejectedAndEdgeClipped() {
        let geometry = RecognitionGeometry(imageSize: CGSize(width: 900, height: 1200),
            region: CaptureRegion(left: 10.0/900, top: 0.1, right: 150.0/900, bottom: 0.1))
        XCTAssertNil(geometry.cameraBox(fromVision: CGRect(x: 0, y: 0.4, width: 0.02, height: 0.1)))
        let clipped = geometry.cameraBox(fromVision: CGRect(x: 0.05, y: 0.4, width: 0.3, height: 0.1))!
        XCTAssertEqual(clipped.minX, 10.0/900, accuracy: 0.000001)
    }
    func testLandscapeLetterboxAndFullFrame() {
        let geometry = RecognitionGeometry(imageSize: CGSize(width: 1200, height: 900), region: .init(left: 0, top: 0, right: 0, bottom: 0))
        XCTAssertEqual(geometry.padding.x, 0)
        XCTAssertEqual(geometry.padding.y, 52)
        XCTAssertEqual(geometry.cameraBox(fromVision: CGRect(x: 0, y: 0.125, width: 1, height: 0.75)), CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
