import Foundation

/// Suppress repeated conclusions after recognition, never before it can run.
/// Keep the last emitted baseline fixed so small jitter cannot accumulate.
public struct ReportedRollFilter: Sendable {
    private var previous: [RollFace]?
    private var eventID = ""
    public init() {}
    public func duplicateEventID(for faces: [RollFace]) -> String? {
        guard let previous, previous.count == faces.count else { return nil }
        var remaining = previous
        for face in faces {
            guard let i = remaining.firstIndex(where: {
                $0.value == face.value && abs(($0.box.x + $0.box.width / 2) - (face.box.x + face.box.width / 2)) < 0.01 &&
                abs(($0.box.y + $0.box.height / 2) - (face.box.y + face.box.height / 2)) < 0.01
            }) else { return nil }
            remaining.remove(at: i)
        }
        return eventID
    }
    public mutating func record(_ faces: [RollFace], eventID: String) { previous = faces; self.eventID = eventID }
}
