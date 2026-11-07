import SwiftUI
import AVFoundation
import DiceCaptureCore

private let ink = Color(red: 0.06, green: 0.15, blue: 0.17)
private let mint = Color(red: 0.24, green: 0.85, blue: 0.68)

struct CaptureView: View {
    @ObservedObject var model: CaptureViewModel
    @ObservedObject private var camera: CameraService
    @ObservedObject private var recognition: DiceRecognizer
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = false
    @State private var library = false
    @State private var newSession = false
    @State private var notes = ""
    init(model: CaptureViewModel) { self.model = model; camera = model.camera; recognition = model.camera.recognizer }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recognition.settled && !recognition.dice.isEmpty ? "\(recognition.dice.count) dice · Total \(recognition.dice.reduce(0) { $0 + $1.value })" : "Reading dice…")
                                .font(.title2.bold()).accessibilityIdentifier("roll-result")
                            Text(recognition.message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("recognition-status")
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(model.records.count)").font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                                .accessibilityLabel("Saved photos").accessibilityValue(String(model.records.count)).accessibilityIdentifier("saved-count")
                            Text("saved this session").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ZStack {
                        CameraPreview(session: camera.session)
                        if let demoImage = camera.demoImage { Image(uiImage: demoImage).resizable().scaledToFit() }
                        if camera.ready { TrayOverlay(region: model.region); DiceOverlay(dice: recognition.dice, settled: recognition.settled) }
                        if !camera.ready {
                            VStack(spacing: 14) {
                                Image(systemName: "camera.viewfinder").font(.largeTitle)
                                Text(camera.status).multilineTextAlignment(.center)
                                if camera.permissionDenied {
                                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                                } else { Button("Retry camera") { camera.start() } }
                            }.foregroundStyle(.white).padding(28)
                        }
                    }
                    .aspectRatio(3/4, contentMode: .fit).background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(alignment: .topLeading) {
                        Label(camera.isDemo ? "SIMULATOR FIXTURE" : "REAR CAMERA · 1×", systemImage: "camera")
                            .font(.caption2.bold()).padding(10).background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white).padding(12)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle().fill(camera.automatic ? mint : Color.secondary).frame(width: 8, height: 8)
                            Text(camera.status).font(.subheadline.weight(.medium)).accessibilityIdentifier("capture-status")
                            Spacer()
                            if camera.saving { ProgressView() }
                        }
                        ProgressView(value: camera.progress).tint(mint)
                        Text("Experimental: check every highlighted face, especially touching dice. The camera button saves a failure; auto capture saves one photo per still scene.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let session = model.currentSession {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.bold())
                                Text(session.notes.isEmpty ? "Add rig and lighting notes in a new session." : session.notes).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { Task { await model.export(session) } } label: { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("Export current session ZIP").accessibilityIdentifier("export-session")
                                .disabled(model.records.isEmpty || camera.saving || model.exporting)
                        }.padding(14).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
                    }
                    #if DEBUG && targetEnvironment(simulator)
                    if camera.isDemo { Button("Next arrangement") { camera.nextDemoArrangement() }.accessibilityIdentifier("next-arrangement") }
                    #endif
                }.padding(18)
            }
            .background(Color(red: 0.97, green: 0.97, blue: 0.94))
            .foregroundStyle(ink)
            .navigationTitle("DiceTower Capture").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { library = true } label: { Image(systemName: "photo.stack") }.accessibilityLabel("Sessions and photos").accessibilityIdentifier("open-library")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { notes = ""; newSession = true; camera.setAutomatic(false) } label: { Image(systemName: "plus") }.accessibilityLabel("New capture session").disabled(camera.saving)
                    Button { settings = true; camera.setAutomatic(false) } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Capture settings").disabled(camera.saving)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 14) {
                    Button {
                        if camera.automatic { camera.setAutomatic(false) }
                        else { Task { await model.startAuto() } }
                    } label: {
                        Label(camera.automatic ? "Pause auto capture" : "Start auto capture", systemImage: camera.automatic ? "pause.fill" : "play.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                    }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(ink).accessibilityIdentifier("toggle-auto")
                    Button { Task { await model.manualPhoto() } } label: { Image(systemName: "camera.fill").font(.title2).frame(width: 52, height: 52) }
                        .buttonStyle(.bordered).tint(ink).accessibilityLabel("Take photo now").accessibilityIdentifier("manual-photo")
                }.disabled(!camera.ready || camera.saving || model.loading || model.exporting)
                    .padding(.horizontal, 18).padding(.vertical, 10).background(.regularMaterial)
            }
            .sheet(isPresented: $settings) { CaptureSettingsView(model: model) }
            .sheet(isPresented: $library) { SessionLibraryView(model: model) }
            .sheet(isPresented: $newSession) {
                NavigationStack {
                    Form {
                        Section("Rig and lighting notes") {
                            TextField("Dice set, felt, mount height, lighting…", text: $notes, axis: .vertical).lineLimit(4...8)
                        }
                        Section { Text("Start a new session when you change the rig, dice set, or lighting. Photos are saved on this phone and exported for labeling later.") }
                    }.navigationTitle("New session")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { newSession = false } }
                            ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await model.newSession(notes: notes); newSession = false } } }
                        }
                }.presentationDetents([.medium, .large])
            }
            .sheet(item: Binding(get: { library ? nil : model.shareArtifact }, set: { model.shareArtifact = $0 })) { artifact in ActivitySheet(url: artifact.url) }
            .alert("Capture needs attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .overlay { if model.exporting { ProgressView("Preparing session ZIP…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
            .task { await model.load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && !model.loading { camera.start() }
                else if phase != .active { camera.suspend() }
            }
        }.tint(ink)
    }
}

private struct TrayOverlay: View {
    let region: CaptureRegion
    var body: some View {
        GeometryReader { geometry in
            let crop = CGRect(x: geometry.size.width * region.left, y: geometry.size.height * region.top,
                              width: geometry.size.width * (1 - region.left - region.right), height: geometry.size.height * (1 - region.top - region.bottom))
            Path { path in path.addRect(CGRect(origin: .zero, size: geometry.size)); path.addRect(crop) }
                .fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
            Path { $0.addRect(crop) }.stroke(mint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
}
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(); view.previewLayer.session = session; view.previewLayer.videoGravity = .resizeAspect; return view
    }
    func updateUIView(_ view: PreviewUIView, context: Context) {}
}

struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct CaptureSettingsView: View {
    @ObservedObject var model: CaptureViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    CameraPreview(session: model.camera.session)
                    if let image = model.camera.demoImage { Image(uiImage: image).resizable().scaledToFit() }
                    TrayOverlay(region: model.region)
                }.frame(width: 150, height: 200).background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12)).padding(10)
            Form {
                Section("Wait for stillness") {
                    LabeledContent("Settling time", value: String(format: "%.1f seconds", model.parameters.settleDuration))
                    Slider(value: $model.parameters.settleDuration, in: 0.6...3, step: 0.1).accessibilityLabel("Settling time")
                    Picker("Motion sensitivity", selection: $model.parameters.motionThreshold) {
                        Text("High").tag(0.006); Text("Normal").tag(0.012); Text("Low").tag(0.024)
                    }
                    Text("Use High if a moving die is missed. Use Low if sensor noise keeps the scene from settling.").font(.footnote)
                }
                Section("Tray area") {
                    Text("Match the dashed frame to the inside of the tray. This area is used for recognition and movement detection; the complete photo is saved. Keep every die inside it.").font(.footnote)
                    inset("Left", $model.region.left); inset("Right", $model.region.right)
                    inset("Top", $model.region.top); inset("Bottom", $model.region.bottom)
                    Button("Reset tray area") { model.region = .init(left: 10.0/900, top: 0.1, right: 150.0/900, bottom: 0.1) }
                }
                Section("Camera") {
                    Toggle("Lock focus, exposure & white balance", isOn: $model.lockCamera)
                    Text("Let the camera adjust to the tray first, then lock it for consistent photos. Flash stays off and the rear wide camera stays at 1×.").font(.footnote)
                }
                Section("Storage") { Text("Original JPEGs and capture metadata stay in DiceTower’s Documents folder. Export a session ZIP using Share, or copy the DiceTower folder using Files/Finder. Live model predictions are experimental and are not saved as approved labels.").font(.footnote) }
            }
            }.navigationTitle("Capture settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func inset(_ name: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(name, value: "\(Int((value.wrappedValue * 100).rounded()))%")
            Slider(value: value, in: 0...0.45, step: 0.01).accessibilityLabel("\(name) tray inset")
        }
    }
}

private struct SessionLibraryView: View {
    @ObservedObject var model: CaptureViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if model.sessions.isEmpty { ContentUnavailableView("No sessions yet", systemImage: "photo.stack", description: Text("Start auto capture or take a photo to begin.")) }
                ForEach(model.sessions) { session in
                    NavigationLink {
                        SessionPhotosView(model: model, session: session)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(session.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("\(model.counts[session.id, default: 0]) photos · \(session.notes.isEmpty ? "No rig notes" : session.notes)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }.navigationTitle("Sessions")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(item: $model.shareArtifact) { artifact in ActivitySheet(url: artifact.url) }
        }
    }
}

private struct SessionPhotosView: View {
    @ObservedObject var model: CaptureViewModel
    let session: CaptureSession
    @State private var records: [CaptureRecord] = []
    @State private var selected: CaptureRecord?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                ForEach(records) { record in
                    Button { selected = record } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if let image = UIImage(contentsOfFile: model.store.captureURL(record.id, session: session.id).appendingPathComponent("thumbnail.jpg").path) {
                                Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            Text(record.capturedAt.formatted(date: .omitted, time: .standard)).font(.caption2)
                        }
                    }.accessibilityLabel("Photo at \(record.capturedAt.formatted(date: .omitted, time: .standard))")
                }
            }.padding()
        }.navigationTitle("\(records.count) photos")
            .toolbar { Button { Task { await model.export(session) } } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Export session ZIP").disabled(records.isEmpty || model.exporting || model.camera.saving) }
            .task { do { records = try await model.store.records(in: session.id) } catch { model.errorMessage = error.localizedDescription } }
            .sheet(item: $selected) { record in
                NavigationStack {
                    VStack(spacing: 16) {
                        if let image = UIImage(contentsOfFile: model.store.captureURL(record.id, session: session.id).appendingPathComponent("image.jpg").path) {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                        Text("\(record.trigger.capitalized) · Unlabeled").font(.headline)
                        Text(record.capturedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    }.padding().navigationTitle("Captured photo").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selected = nil } } }
                }
            }
    }
}

private struct DiceOverlay: View {
    let dice: [RecognizedDie]
    let settled: Bool
    var body: some View {
        GeometryReader { geometry in
            ForEach(dice) { die in
                let rect = CGRect(x: die.box.minX * geometry.size.width, y: die.box.minY * geometry.size.height,
                                  width: die.box.width * geometry.size.width, height: die.box.height * geometry.size.height)
                RoundedRectangle(cornerRadius: 4).stroke(settled ? mint : .yellow, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                Text("\(die.value)").font(.system(.body, design: .rounded, weight: .bold)).foregroundStyle(.black)
                    .padding(4).background(settled ? mint : .yellow, in: RoundedRectangle(cornerRadius: 4))
                    .position(x: rect.midX, y: max(14, rect.minY - 13))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
