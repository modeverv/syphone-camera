import SwiftUI

@main
struct SyphonUniCamExReceiverApp: App {
    @StateObject private var model: ReceiverAppModel

    init() {
        let model = ReceiverAppModel()
        _model = StateObject(wrappedValue: model)
        model.startFromLaunchArguments()
    }

    var body: some Scene {
        WindowGroup {
            ReceiverContentView().environmentObject(model).frame(minWidth: 520, minHeight: 280)
        }
    }
}
