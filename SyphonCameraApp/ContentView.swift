import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Syphon Camera")
                .font(.title)

            Text(model.status)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Picker("Input", selection: $model.inputMode) {
                ForEach(AppModel.InputMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if model.inputMode == .syphon {
                HStack {
                    TextField("Syphon server name contains…", text: $model.syphonNameFilter)
                    Button("Refresh") { model.refreshSyphonServers() }
                }
                List(model.syphonServers, id: \.self, selection: $model.selectedSyphonServer) {
                    Text($0)
                }
                .frame(minHeight: 110)
            }

            HStack {
                Button("Activate Camera Extension") {
                    model.activateExtension()
                }
                Button(model.isRunning ? "Stop Bridge" : "Start Bridge") {
                    model.toggleBridge()
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider()
            Text("Output: 1280×720 / 30 fps / BGRA / queue depth 1")
                .font(.caption)
            Text("Start with Test Pattern. After the virtual camera appears in QuickTime/Meet, attach Syphon.framework and switch to Syphon.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear {
            model.refreshSyphonServers()
        }
    }
}
