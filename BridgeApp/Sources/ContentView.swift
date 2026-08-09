import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Syphon → UniCamEx Bridge")
                .font(.title2)
                .bold()

            Picker("Source", selection: $model.selectedSource) {
                Text("Test Pattern").tag(SourceKind.testPattern)
                Text("Syphon").tag(SourceKind.syphon)
                Text("Network").tag(SourceKind.network)
            }
            .pickerStyle(.segmented)

            if model.selectedSource == .network {
                HStack {
                    TextField("Sender host", text: $model.networkHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("Port", text: $model.networkPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            HStack {
                Button(model.isRunning ? "Stop" : "Start") {
                    model.isRunning ? model.stop() : model.start()
                }
                .keyboardShortcut(.defaultAction)

                Button("Send Single Diagnostic Frame") {
                    model.sendSingleDiagnosticFrame()
                }

                Button("Run Network Loopback") {
                    model.runNetworkLoopback()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Status: \(model.status)")
                Text("Resolution: \(model.width)x\(model.height) @ \(model.fps) fps")
                    .font(.system(.body, design: .monospaced))
                Text("Notes: install UniCamEx first, then verify its camera in QuickTime.")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
    }
}
