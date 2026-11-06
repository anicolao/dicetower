import SwiftUI

@main struct DiceTowerApp: App {
    @StateObject private var model = CaptureViewModel()
    var body: some Scene {
        WindowGroup { CaptureView(model: model) }
    }
}
