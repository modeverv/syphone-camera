import Foundation
import SwiftUI

@MainActor
final class ReceiverAppModel: ObservableObject {
    @Published var port = "5001"
    @Published var status = "Idle"
    @Published var isRunning = false

    let width = 1920
    let height = 1080
    let fps = 30
    private var engine: BridgeEngine?

    func startFromLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--port"), arguments.indices.contains(index + 1) { port = arguments[index + 1] }
        start()
    }

    func start() {
        guard let networkPort = UInt16(port), networkPort > 0 else {
            status = "Invalid network port"
            return
        }
        stop()
        do {
            let engine = BridgeEngine()
            try engine.start(source: .network, width: width, height: height, fps: fps,
                             networkPort: networkPort, networkTransport: .udp)
            self.engine = engine
            status = "Receiving H.264/UDP on port \(networkPort)"
            isRunning = true
        } catch {
            status = "Start failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        isRunning = false
        if status != "Idle" { status = "Stopped" }
    }
}
