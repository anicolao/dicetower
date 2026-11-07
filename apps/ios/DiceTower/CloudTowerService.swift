import Foundation
import Combine
import Security
import DiceCaptureCore

struct CloudProfile: Codable, Sendable {
    let id: String
    let name: String
}
struct CloudRoll: Codable, Sendable {
    var schemaVersion = 1
    let eventId: String
    let rollId: String
    let kind: String
    let capturedAt: Double
    var modelSHA256 = "416678e1d7e4e7f7b867e1513fce072744a49c6feca3cdfb90b12417be8091b9"
    let dice: [RollFace]
    let count: Int
    let total: Int
    let thumbnail: String
    var experimental = true
}

@MainActor final class CloudTowerService: ObservableObject {
    @Published private(set) var profile: CloudProfile?
    @Published private(set) var sharing: Bool
    @Published private(set) var queued = 0
    @Published private(set) var queuedMetrics = 0
    @Published private(set) var heldUploads = 0
    @Published private(set) var uploadIssue = ""
    @Published private(set) var status = "Roll sharing is off"
    @Published private(set) var busy = false
    @Published var showSetup = false
    private let client: FirebaseTowerClient?
    private var worker: Task<Void, Never>?
    private var flushing = false
    private var flushRequested = false
    private var latestMetric: RecognitionMetrics?

    init() {
        #if DEBUG && targetEnvironment(simulator)
        let offlineFixture = ProcessInfo.processInfo.arguments.contains("-capture-demo") && !ProcessInfo.processInfo.arguments.contains("-cloud-demo")
        client = offlineFixture ? nil : try? FirebaseTowerClient()
        #else
        client = try? FirebaseTowerClient()
        #endif
        if let data = UserDefaults.standard.data(forKey: "cloudTowerProfile") {
            profile = try? JSONDecoder().decode(CloudProfile.self, from: data)
        }
        sharing = UserDefaults.standard.bool(forKey: "cloudTowerSharing")
    }
    func start() {
        #if DEBUG && targetEnvironment(simulator)
        // Existing collection UI tests stay offline. Cloud QA opts in explicitly.
        if ProcessInfo.processInfo.arguments.contains("-capture-demo") && !ProcessInfo.processInfo.arguments.contains("-cloud-demo") { return }
        #endif
        if !UserDefaults.standard.bool(forKey: "cloudTowerOnboarded") { showSetup = true }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.flush()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
    func configure(name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 60, let client else { status = "Enter a tower name (1–60 characters)."; return false }
        busy = true; defer { busy = false }
        do {
            let profile = try await client.register(name: name, sharing: true)
            self.profile = profile; sharing = true
            UserDefaults.standard.set(try JSONEncoder().encode(profile), forKey: "cloudTowerProfile")
            UserDefaults.standard.set(true, forKey: "cloudTowerSharing")
            UserDefaults.standard.set(true, forKey: "cloudTowerOnboarded")
            status = "Sharing as \(name)"; showSetup = false
            await flush()
            return true
        } catch { status = "Could not connect: \(error.localizedDescription)"; return false }
    }
    func keepLocal() {
        sharing = false
        UserDefaults.standard.set(false, forKey: "cloudTowerSharing")
        UserDefaults.standard.set(true, forKey: "cloudTowerOnboarded")
        status = "Roll sharing is off"; showSetup = false
        if let profile, let client { Task { await client.pause(); _ = try? await client.register(name: profile.name, sharing: false) } }
    }
    func receive(_ roll: CloudRoll) async {
        guard sharing, let profile, let client else { return }
        guard roll.count <= 30, roll.thumbnail.utf8.count <= 100000 else { status = "Reading too large to share · try again"; return }
        do { try await client.enqueue(roll, towerID: profile.id); await flush() }
        catch { status = "Roll could not be queued: \(error.localizedDescription)" }
    }
    func receiveMetrics(_ sample: RecognitionMetrics) async {
        guard sharing, let profile, let client else { return }
        var sample = sample
        sample.uploadHeldCount = heldUploads; sample.uploadIssue = uploadIssue
        latestMetric = sample
        do { try await client.enqueueMetric(sample, towerID: profile.id); await flush() }
        catch { status = "Metrics could not be queued: \(error.localizedDescription)" }
    }
    func retryHeldUploads() async {
        guard let client else { return }
        do { try await client.retryHeld(); await refreshHeld(); await flush() }
        catch { status = "Could not retry held uploads: \(error.localizedDescription)" }
    }
    private func refreshHeld() async {
        guard let client else { return }
        let value = await client.heldStatus()
        let changed = heldUploads != value.count || uploadIssue != value.issue
        heldUploads = value.count; uploadIssue = value.issue
        if changed, sharing, let profile, var sample = latestMetric {
            sample.metricId = UUID().uuidString; sample.recordedAt = Date().timeIntervalSince1970 * 1000
            sample.duplicateDiscarded = false; sample.duplicateOfEventId = ""
            sample.uploadHeldCount = value.count; sample.uploadIssue = value.issue
            // This is a delivery-status snapshot, not another recognition event.
            sample.eventId = ""
            do { try await client.enqueueMetric(sample, towerID: profile.id); flushRequested = true }
            catch { status = "Upload diagnostics could not be saved: \(error.localizedDescription)" }
        }
    }
    func flush() async {
        guard sharing, let profile, let client else { return }
        flushRequested = true
        guard !flushing else { return }
        flushing = true; defer { flushing = false }
        do {
            // A sample arriving during a request asks for another drain immediately.
            // The final quiescent sample must not wait for the 15s recovery timer.
            while sharing && flushRequested {
                flushRequested = false
                queued = try await client.pendingCount()
                queuedMetrics = try await client.pendingMetricsCount()
                try await client.flush(towerID: profile.id)
                await refreshHeld()
                queued = try await client.pendingCount()
                queuedMetrics = try await client.pendingMetricsCount()
                if queued > 0 || queuedMetrics > 0 { flushRequested = true }
            }
            if sharing { status = heldUploads > 0 ? "\(heldUploads) held · \(uploadIssue) · other uploads continue" : "Live · \(profile.name)" }
        } catch {
            await refreshHeld()
            queued = (try? await client.pendingCount()) ?? queued
            queuedMetrics = (try? await client.pendingMetricsCount()) ?? queuedMetrics
            status = "\(queued) rolls, \(queuedMetrics) metrics queued; \(heldUploads) held · \(error.localizedDescription)"
        }
    }
}

/// Firebase's documented REST endpoints keep the native app dependency-free.
/// The anonymous identity is stored in Keychain; durable event IDs make retries safe.
actor FirebaseTowerClient {
    private struct Configuration: Decodable { let apiKey: String; let databaseURL: String }
    private struct Identity: Codable { let uid: String; var refreshToken: String; var idToken: String; var expires: Date }
    private struct Pending: Codable { let towerID: String; let roll: CloudRoll }
    private struct PendingMetric: Codable { let towerID: String; let metric: RecognitionMetrics }
    private let config: Configuration
    private let directory: URL
    private var identity: Identity?
    private var authenticating: Task<Identity, Error>?
    private let session: URLSession
    private var lastHeartbeat = Date.distantPast
    private var publishing = true
    func pause() { publishing = false }
    private static let keychainService = "org.boardgamescafe.dicetower.firebase"

    init() throws {
        guard let url = Bundle.main.url(forResource: "FirebaseConfig", withExtension: "json") else { throw CloudError.configuration }
        config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiceTower/CloudOutbox", isDirectory: true)
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 20; settings.timeoutIntervalForResource = 30
        session = URLSession(configuration: settings)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                     kSecAttrAccount as String: "anonymous", kSecReturnData as String: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            identity = try JSONDecoder().decode(Identity.self, from: data)
        }
    }
    private func authenticated() async throws -> Identity {
        if let identity, identity.expires.timeIntervalSinceNow > 120 { return identity }
        if let authenticating { return try await authenticating.value }
        let current = identity, config = config, session = session
        let task = Task<Identity, Error> {
            var request: URLRequest
            if let current {
                request = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(config.apiKey)")!)
                request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                var form = URLComponents(); form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"),URLQueryItem(name: "refresh_token", value: current.refreshToken)]
                request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
            } else {
                request = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(config.apiKey)")!)
                request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data("{\"returnSecureToken\":true}".utf8)
            }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CloudError.authentication }
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard let uid = result["localId"] as? String ?? result["user_id"] as? String,
                  let refresh = result["refreshToken"] as? String ?? result["refresh_token"] as? String,
                  let token = result["idToken"] as? String ?? result["id_token"] as? String else { throw CloudError.authentication }
            return Identity(uid: uid, refreshToken: refresh, idToken: token, expires: Date().addingTimeInterval(3500))
        }
        authenticating = task
        defer { authenticating = nil }
        let value = try await task.value
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: "anonymous"]
        let bytes = try JSONEncoder().encode(value)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if update == errSecItemNotFound {
            var new = query; new[kSecValueData as String] = bytes; new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw CloudError.keychain }
        } else if update != errSecSuccess { throw CloudError.keychain }
        identity = value
        return value
    }
    private func database(_ path: String, method: String = "GET", body: Data? = nil, createOnly: Bool = false) async throws -> (Data, Int) {
        let identity = try await authenticated()
        var url = URLComponents(string: config.databaseURL + "/" + path + ".json")!
        url.queryItems = [URLQueryItem(name: "auth", value: identity.idToken)]
        var request = URLRequest(url: url.url!); request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if createOnly { request.setValue("null_etag", forHTTPHeaderField: "if-match") }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { self.identity?.expires = .distantPast }
        guard (200...299).contains(code) || (createOnly && code == 412) else { throw CloudError.database(code) }
        return (data, code)
    }
    func register(name: String, sharing: Bool) async throws -> CloudProfile {
        let identity = try await authenticated()
        publishing = sharing
        let (data, _) = try await database("towers/\(identity.uid)")
        let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let metadata: [String: Any] = ["name": name, "createdAt": existing?["createdAt"] ?? [".sv": "timestamp"],
                                       "updatedAt": [".sv": "timestamp"], "sharing": sharing, "schemaVersion": 1]
        _ = try await database("towers/\(identity.uid)", method: "PUT", body: JSONSerialization.data(withJSONObject: metadata))
        return CloudProfile(id: identity.uid, name: name)
    }
    func enqueue(_ roll: CloudRoll, towerID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Pending(towerID: towerID, roll: roll)).write(to: directory.appendingPathComponent(roll.eventId + ".json"), options: .atomic)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-upload-poison-demo"),
           ProcessInfo.processInfo.arguments.contains("-cloud-demo"),
           !FileManager.default.fileExists(atPath: directory.appendingPathComponent("poison-qa-seeded").path) {
            // Explicit, live-QA-only fault injection: a bad middle UUID and a bad
            // metric must not block either valid end of the queue or telemetry.
            let encoded = try JSONEncoder().encode(Pending(towerID: towerID, roll: roll))
            let ids = ["0" + UUID().uuidString.dropFirst(), "F" + UUID().uuidString.dropFirst()]
            for id in ids {
                var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                var value = object["roll"] as! [String: Any]; value["eventId"] = id; value["rollId"] = id; object["roll"] = value
                try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(id + ".json"), options: .atomic)
            }
            try Data("not JSON".utf8).write(to: directory.appendingPathComponent("A0000000-0000-4000-8000-000000000001.json"), options: .atomic)
            let metrics = directory.appendingPathComponent("metrics"); try FileManager.default.createDirectory(at: metrics, withIntermediateDirectories: true)
            try Data("not JSON".utf8).write(to: metrics.appendingPathComponent("A0000000-0000-4000-8000-000000000002.json"), options: .atomic)
            try JSONEncoder().encode(ids).write(to: directory.appendingPathComponent("poison-qa-seeded"), options: .atomic)
        }
        #endif
    }
    func enqueueMetric(_ metric: RecognitionMetrics, towerID: String) throws {
        let folder = directory.appendingPathComponent("metrics", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(PendingMetric(towerID: towerID, metric: metric)).write(to: folder.appendingPathComponent(metric.metricId + ".json"), options: .atomic)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-upload-poison-demo"),
           ProcessInfo.processInfo.arguments.contains("-cloud-demo"),
           !FileManager.default.fileExists(atPath: directory.appendingPathComponent("poison-metric-seeded").path) {
            let id = "B0000000-0000-4000-8000-000000000003"
            var bad = metric; bad.metricId = id; bad.settleMs = 201
            try JSONEncoder().encode(PendingMetric(towerID: towerID, metric: bad)).write(to: folder.appendingPathComponent(id + ".json"), options: .atomic)
            try Data().write(to: directory.appendingPathComponent("poison-metric-seeded"), options: .atomic)
        }
        #endif
    }
    private func metricFiles() throws -> [URL] {
        let folder = directory.appendingPathComponent("metrics", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func pendingMetricsCount() throws -> Int { try metricFiles().count }
    func pendingCount() throws -> Int { try pendingFiles().count }
    private func pendingFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private var quarantine: UploadQuarantine { UploadQuarantine(root: directory.appendingPathComponent("Held")) }
    func heldStatus() -> HeldUploadStatus { quarantine.status() }
    func retryHeld() throws { try quarantine.retry { kind in kind == "rolls" ? directory : directory.appendingPathComponent("metrics") } }
    private func uploadEnabled() -> Bool { publishing }
    nonisolated private static func permanent(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        if let error = error as? CocoaError,
           [.fileReadCorruptFile, .fileReadNoPermission, .fileReadTooLarge].contains(error.code) { return true }
        if let error = error as? CloudError {
            switch error {
            case .database(let code): return [400,403,413,422].contains(code)
            case .queuedIdentity, .acknowledgement: return true
            default: return false
            }
        }
        return false
    }
    private func hold(_ file: URL, kind: String, error: Error) throws {
        let reason = "\(kind == "rolls" ? "Roll" : "Metric") \(file.deletingPathExtension().lastPathComponent.prefix(8)): \(error.localizedDescription)"
        try quarantine.hold(file, kind: kind, reason: String(decoding: reason.utf16.prefix(180), as: UTF16.self))
    }
    private func sendRoll(_ file: URL, towerID: String) async throws {
        let pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: file))
        guard pending.towerID == towerID else { throw CloudError.queuedIdentity }
        var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pending.roll)) as! [String: Any]
        payload["receivedAt"] = [".sv": "timestamp"]
        let (data, code) = try await database("rolls/\(towerID)/\(pending.roll.eventId)", method: "PUT", body: JSONSerialization.data(withJSONObject: payload), createOnly: true)
        if code == 412 {
            let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard existing?["eventId"] as? String == pending.roll.eventId else { throw CloudError.acknowledgement }
        }
        try FileManager.default.removeItem(at: file)
    }
    private func flushMetrics(towerID: String) async throws {
        var records: [(URL, PendingMetric)] = []
        for file in try metricFiles().prefix(100) {
            guard publishing else { return }
            do {
                let pending = try JSONDecoder().decode(PendingMetric.self, from: Data(contentsOf: file))
                guard pending.towerID == towerID else { throw CloudError.queuedIdentity }
                records.append((file, pending))
            } catch {
                guard Self.permanent(error) else { throw error }
                try hold(file, kind: "metrics", error: error)
            }
        }
        guard publishing, !records.isEmpty else { return }
        try await sendMetricBatch(records, towerID: towerID)
    }
    private func sendMetricBatch(_ records: [(URL, PendingMetric)], towerID: String) async throws {
        guard publishing, !records.isEmpty else { return }
        var batch: [String: Any] = [:]
        for (_, pending) in records { batch[pending.metric.metricId] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pending.metric)) }
        do {
            _ = try await database("metrics/\(towerID)", method: "PATCH", body: JSONSerialization.data(withJSONObject: batch))
        } catch {
            guard Self.permanent(error) else { throw error }
            if records.count == 1 {
                try hold(records[0].0, kind: "metrics", error: error)
            } else {
                // Bisect rejected atomic batches: acknowledge healthy halves in
                // bulk instead of delaying live rolls behind 100 single writes.
                let middle = records.count / 2
                try await sendMetricBatch(Array(records[..<middle]), towerID: towerID)
                try await sendMetricBatch(Array(records[middle...]), towerID: towerID)
            }
            return
        }
        for (file, _) in records { try FileManager.default.removeItem(at: file) }
    }
    func flush(towerID: String) async throws {
        let identity = try await authenticated()
        guard identity.uid == towerID else { throw CloudError.identity }
        if Date().timeIntervalSince(lastHeartbeat) > 60 {
            _ = try await database("towers/\(towerID)", method: "PATCH", body: JSONSerialization.data(withJSONObject: ["updatedAt": [".sv": "timestamp"], "sharing": true]))
            lastHeartbeat = Date()
        }
        var rollError: Error?
        do {
            try await drainUploadFiles(try pendingFiles(), enabled: { await self.uploadEnabled() },
                deliver: { try await self.sendRoll($0, towerID: towerID) }, permanent: { Self.permanent($0) },
                hold: { try await self.hold($0, kind: "rolls", error: $1) })
        } catch { rollError = error }
        // Even a transient roll failure cannot prevent the metrics stream trying.
        do { try await flushMetrics(towerID: towerID) }
        catch { throw rollError ?? error }
        if let rollError { throw rollError }
    }
    private enum CloudError: LocalizedError {
        case configuration, authentication, keychain, identity, queuedIdentity, acknowledgement, database(Int)
        var errorDescription: String? {
            switch self {
            case .configuration: return "Firebase configuration is missing."
            case .authentication: return "Anonymous sign-in failed. Please try again."
            case .keychain: return "Could not save the tower identity securely."
            case .identity: return "This queued roll belongs to a different tower identity."
            case .queuedIdentity: return "Saved upload belongs to another tower; original data retained."
            case .acknowledgement: return "Server record did not acknowledge this event; original data retained."
            case .database(let status): return "Firebase request failed (\(status))."
            }
        }
    }
}
