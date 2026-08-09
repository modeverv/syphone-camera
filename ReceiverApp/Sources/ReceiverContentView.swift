import SwiftUI

struct ReceiverContentView: View {
    @EnvironmentObject var model: ReceiverAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Syphon UniCamEx Receiver")
                .font(.title2).bold()
            Text("UDP → H.264 hardware decode → UniCamEx")
                .foregroundStyle(.secondary)
            TextField("UDP port", text: $model.port).textFieldStyle(.roundedBorder).frame(width: 120)
            Button(model.isRunning ? "Stop" : "Start") {
                model.isRunning ? model.stop() : model.start()
            }
            .keyboardShortcut(.defaultAction)
            Text("Status: \(model.status)")
            Text("Resolution: \(model.width)x\(model.height) @ \(model.fps) fps")
                .font(.system(.body, design: .monospaced))
            Text("Install UniCamEx, then select it in the camera client.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }
}
