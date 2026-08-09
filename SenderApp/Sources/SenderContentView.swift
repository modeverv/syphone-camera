import SwiftUI

struct SenderContentView: View {
    @EnvironmentObject var model: SenderAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Syphon UniCamEx Sender")
                .font(.title2).bold()
            Text("Input → H.264 hardware encode → UDP")
                .foregroundStyle(.secondary)
            Picker("Input", selection: $model.input) {
                ForEach(SenderInput.allCases) { input in
                    Text(input.label).tag(input)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.input) { _ in
                if model.isRunning { model.start() }
            }
            HStack {
                TextField("Receiver host", text: $model.host).textFieldStyle(.roundedBorder)
                TextField("Port", text: $model.port).textFieldStyle(.roundedBorder).frame(width: 80)
            }
            Button(model.isRunning ? "Stop" : "Start") {
                model.isRunning ? model.stop() : model.start()
            }
            .keyboardShortcut(.defaultAction)
            Text("Status: \(model.status)")
            Text("Resolution: \(model.width)x\(model.height) @ \(model.fps) fps")
                .font(.system(.body, design: .monospaced))
            Spacer()
        }
        .padding(20)
    }
}
