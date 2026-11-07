import Foundation
import CoreGraphics

/// Maps a square, black-letterboxed model input to the upright camera image.
/// All public rectangles use normalized top-left coordinates.
public struct RecognitionGeometry: Sendable {
    public let crop: CGRect
    public let scaleX: Double
    public let scaleY: Double
    public let padding: CGPoint
    public let imageSize: CGSize
    public init(imageSize: CGSize, region: CaptureRegion) {
        self.imageSize = imageSize
        // Round just once, matching the image crop used at inference.
        let x = (imageSize.width * region.left).rounded()
        let y = (imageSize.height * region.top).rounded()
        let right = (imageSize.width * (1 - region.right)).rounded()
        let bottom = (imageSize.height * (1 - region.bottom)).rounded()
        crop = CGRect(x: x, y: y, width: max(1, right - x), height: max(1, bottom - y))
        let fit = 416 / max(crop.width, crop.height)
        let width = (crop.width * fit).rounded(), height = (crop.height * fit).rounded()
        scaleX = width / crop.width; scaleY = height / crop.height
        padding = CGPoint(x: floor((416 - width) / 2), y: floor((416 - height) / 2))
    }
    public func cameraBox(fromVision box: CGRect) -> CGRect? {
        let pixels = CGRect(x: (box.minX * 416 - padding.x) / scaleX + crop.minX,
                            y: ((1 - box.maxY) * 416 - padding.y) / scaleY + crop.minY,
                            width: box.width * 416 / scaleX, height: box.height * 416 / scaleY)
        // Ignore detections whose centers lie in padding, then clip to the tray.
        guard crop.contains(CGPoint(x: pixels.midX, y: pixels.midY)) else { return nil }
        let clipped = pixels.intersection(crop)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return CGRect(x: clipped.minX / imageSize.width, y: clipped.minY / imageSize.height,
                      width: clipped.width / imageSize.width, height: clipped.height / imageSize.height)
    }
}
