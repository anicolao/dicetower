import Foundation
import CoreGraphics

/// Check the wire contract before a roll becomes a duplicate baseline or upload.
public enum RollUploadValidation {
    public struct Invalid: LocalizedError, Sendable {
        public let field: String
        public var errorDescription: String? { "Invalid roll field: \(field)" }
    }
    public static func faces(_ faces: [RollFace]) throws -> [RollFace] {
        guard faces.count <= 30 else { throw Invalid(field: "count (maximum 30)") }
        return try faces.enumerated().map { i, face in
            guard (1...6).contains(face.value) else { throw Invalid(field: "dice[\(i)].value") }
            guard face.confidence.isFinite else { throw Invalid(field: "dice[\(i)].confidence (non-finite)") }
            let b = face.box
            guard [b.x,b.y,b.width,b.height].allSatisfy({ $0.isFinite }),
                  b.x >= 0, b.y >= 0, b.width > 0, b.height > 0,
                  b.x <= 1, b.y <= 1, b.width <= 1, b.height <= 1,
                  b.x + b.width <= 1.000001, b.y + b.height <= 1.000001
            else { throw Invalid(field: "dice[\(i)].box") }
            return RollFace(value: face.value, confidence: min(1, max(0, face.confidence)),
                            box: CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
        }
    }
    /// Only the known tiny numerical overshoot is eligible for automatic repair.
    public static func hasRecoverableOvershoot(_ faces: [RollFace]) -> Bool {
        faces.contains { $0.confidence > 1 } && faces.allSatisfy {
            $0.confidence.isFinite && $0.confidence >= 0 && $0.confidence <= 1.00001
        }
    }
}
