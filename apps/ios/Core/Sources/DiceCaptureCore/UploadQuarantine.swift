import Foundation

public struct HeldUploadStatus: Sendable {
    public let count: Int
    public let issue: String
}

/// Original bytes are retained; a rejected record must not block unrelated work.
public struct UploadQuarantine: Sendable {
    private let root: URL
    private struct Reason: Codable { let name: String; let kind: String; let message: String; let date: Date }
    public init(root: URL) { self.root = root }
    public func hold(_ file: URL, kind: String, reason: String) throws {
        let directory = root.appendingPathComponent(kind).appendingPathComponent(file.lastPathComponent)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = Reason(name: file.lastPathComponent, kind: kind, message: reason, date: Date())
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("reason.json"), options: .atomic)
        try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("payload.json"))
    }
    private func directories() -> [URL] {
        ["rolls", "metrics"].flatMap { kind in
            (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(kind), includingPropertiesForKeys: nil)) ?? []
        }.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("payload.json").path) }
    }
    public func status() -> HeldUploadStatus {
        let records = directories().compactMap { directory -> Reason? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("reason.json")) else { return nil }
            return try? JSONDecoder().decode(Reason.self, from: data)
        }
        return HeldUploadStatus(count: directories().count, issue: records.max(by: { $0.date < $1.date })?.message ?? "")
    }
    public func retry(destination: (String) -> URL) throws {
        for directory in directories() {
            let metadata = try JSONDecoder().decode(Reason.self, from: Data(contentsOf: directory.appendingPathComponent("reason.json")))
            guard ["rolls", "metrics"].contains(metadata.kind), metadata.name == URL(fileURLWithPath: metadata.name).lastPathComponent else { continue }
            let target = destination(metadata.kind)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: directory.appendingPathComponent("payload.json"), to: target.appendingPathComponent(metadata.name))
            try FileManager.default.removeItem(at: directory)
        }
    }
}

/// Transient failures preserve pending files; permanent failures are isolated.
/// Each stream uses this policy independently, so one stream cannot starve another.
public func drainUploadFiles(_ files: [URL], enabled: @Sendable () async -> Bool,
                             deliver: @Sendable (URL) async throws -> Void,
                             permanent: @Sendable (Error) -> Bool,
                             hold: @Sendable (URL, Error) async throws -> Void) async throws {
    for file in files {
        guard await enabled() else { return }
        do { try await deliver(file) }
        catch {
            guard permanent(error) else { throw error }
            try await hold(file, error)
        }
    }
}
