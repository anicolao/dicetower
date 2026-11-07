import Foundation
import CoreGraphics

public struct RollFace: Codable, Equatable, Sendable {
    public let value: Int
    public let confidence: Double
    public let box: RollBox
    public init(value: Int, confidence: Double, box: CGRect) {
        self.value = value; self.confidence = confidence
        self.box = RollBox(x: box.minX, y: box.minY, width: box.width, height: box.height)
    }
}
public struct RollBox: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

/// One event per movement episode, plus explicit stable recognition revisions.
public struct RollEventGate: Sendable {
    private var armed = true
    private var previous: [RollFace]?
    private var rollID = UUID().uuidString
    public init() {}
    public mutating func moved() { armed = true }
    public mutating func accept(_ faces: [RollFace]) -> (rollID: String, kind: String)? {
        if armed {
            armed = false; previous = faces; rollID = UUID().uuidString
            return (rollID, "roll")
        }
        let same = previous.map { old in
            // Match by proximity instead of x-order, which can flip for stacked dice.
            var remaining = old
            for face in faces {
                guard let i = remaining.firstIndex(where: {
                    $0.value == face.value && abs($0.box.x - face.box.x) < 0.04 && abs($0.box.y - face.box.y) < 0.04
                }) else { return false }
                remaining.remove(at: i)
            }
            return remaining.isEmpty
        } ?? false
        guard !same else { return nil }
        previous = faces
        return (rollID, "recognitionChanged")
    }
}
