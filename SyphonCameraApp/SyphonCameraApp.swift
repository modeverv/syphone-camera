import SwiftUI

@main
struct SyphonCameraApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 360)
        }
    }
}
