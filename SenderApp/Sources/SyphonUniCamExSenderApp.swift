import SwiftUI

@main
struct SyphonUniCamExSenderApp: App {
    @StateObject private var model: SenderAppModel

    init() {
        let model = SenderAppModel()
        _model = StateObject(wrappedValue: model)
        model.startFromLaunchArguments()
    }

    var body: some Scene {
        WindowGroup {
            SenderContentView().environmentObject(model).frame(minWidth: 520, minHeight: 260)
        }
    }
}
