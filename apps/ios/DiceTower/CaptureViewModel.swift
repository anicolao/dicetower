import Foundation
import UIKit
import Combine
import DiceCaptureCore

struct ShareArtifact: Identifiable { let id = UUID(); let url: URL }

@MainActor final class CaptureViewModel: ObservableObject {
    let camera = CameraService()
    let cloud = CloudTowerService()
    let store: CorpusStore
    @Published private(set) var sessions: [CaptureSession] = []
    @Published private(set) var currentSession: CaptureSession?
    @Published private(set) var records: [CaptureRecord] = []
    @Published private(set) var counts: [UUID: Int] = [:]
    @Published private(set) var loading = true
    @Published private(set) var exporting = false
    @Published var errorMessage: String?
    @Published var shareArtifact: ShareArtifact?
    @Published var parameters = CaptureParameters() { didSet { applySettings() } }
    @Published var region = CaptureRegion(left: 10.0/900, top: 0.1, right: 150.0/900, bottom: 0.1) { didSet { applySettings() } }
    @Published var lockCamera = false { didSet { applySettings() } }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        store = CorpusStore(root: documents.appendingPathComponent("DiceTower/Sessions", isDirectory: true))
        if let data = UserDefaults.standard.data(forKey: "captureParameters"), let value = try? JSONDecoder().decode(CaptureParameters.self, from: data) { parameters = value }
        if let data = UserDefaults.standard.data(forKey: "captureRegion"), let value = try? JSONDecoder().decode(CaptureRegion.self, from: data) { region = value }
        camera.onPhoto = { [weak self] data, thumbnail, record, sessionID in
            Task { @MainActor [weak self] in await self?.save(data, thumbnail: thumbnail, record: record, in: sessionID) }
        }
        camera.onError = { [weak self] message in Task { @MainActor in self?.errorMessage = message } }
        camera.recognizer.onRoll = { [weak self] event in
            Task { @MainActor [weak self] in await self?.cloud.receive(event) }
        }
        camera.recognizer.onMetrics = { [weak self] metrics in
            Task { @MainActor [weak self] in await self?.cloud.receiveMetrics(metrics) }
        }
        applySettings()
    }

    func load() async {
        do {
            sessions = try await store.sessions()
            currentSession = sessions.first
            if let currentSession {
                camera.setCorpusSession(currentSession.id)
                records = try await store.records(in: currentSession.id)
            }
            await refreshCounts()
        } catch { errorMessage = error.localizedDescription }
        loading = false
        camera.start()
        cloud.start()
    }

    func startAuto() async {
        guard await ensureSession() else { return }
        camera.setAutomatic(true)
    }
    func manualPhoto() async {
        guard await ensureSession() else { return }
        camera.captureManually()
    }
    private func ensureSession() async -> Bool {
        if currentSession != nil { return true }
        await newSession(notes: "")
        return currentSession != nil
    }

    func newSession(notes: String) async {
        camera.setAutomatic(false)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        var system = utsname(); uname(&system)
        let machine = Mirror(reflecting: system.machine).children.compactMap { $0.value as? Int8 }.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let session = CaptureSession(notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), device: String(bytes: machine, encoding: .utf8) ?? UIDevice.current.model,
                                     operatingSystem: UIDevice.current.systemVersion, appVersion: "\(version) (\(build))")
        do {
            try await store.create(session)
            currentSession = session; records = []; sessions.insert(session, at: 0); counts[session.id] = 0
            camera.setCorpusSession(session.id)
        } catch { errorMessage = error.localizedDescription }
    }

    private func save(_ data: Data, thumbnail: Data?, record: CaptureRecord, in sessionID: UUID) async {
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "Save dice photo", expirationHandler: nil)
        defer { if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) } }
        do {
            let saved = try await store.save(image: data, thumbnail: thumbnail, record: record, in: sessionID)
            if currentSession?.id == sessionID { records.append(saved) }
            counts[sessionID, default: 0] += 1
            camera.completeSave(success: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { camera.completeSave(success: false); errorMessage = "Photo could not be saved: \(error.localizedDescription)" }
    }

    private func refreshCounts() async {
        for session in sessions {
            do { counts[session.id] = try await store.records(in: session.id).count }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func export(_ session: CaptureSession) async {
        guard !camera.saving, !exporting else { return }
        camera.setAutomatic(false); exporting = true
        defer { exporting = false }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("DiceTower-\(session.id.uuidString)-\(UUID().uuidString.prefix(6)).zip")
            let archive = try await store.export(session.id, to: url)
            shareArtifact = ShareArtifact(url: archive)
        } catch { errorMessage = error.localizedDescription }
    }

    private func applySettings() {
        camera.update(parameters: parameters, region: region, lockCamera: lockCamera)
        UserDefaults.standard.set(try? JSONEncoder().encode(parameters), forKey: "captureParameters")
        UserDefaults.standard.set(try? JSONEncoder().encode(region), forKey: "captureRegion")
    }
}
