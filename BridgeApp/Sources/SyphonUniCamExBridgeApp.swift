import SwiftUI

@main
struct SyphonUniCamExBridgeApp: App {
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        model.startFromLaunchArguments()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 340)
        }
    }
}
