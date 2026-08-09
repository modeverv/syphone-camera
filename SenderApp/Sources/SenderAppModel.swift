import Foundation
import SwiftUI

@MainActor
final class SenderAppModel: ObservableObject {
    @Published var input: SenderInput = .testPattern
    @Published var host = "127.0.0.1"
    @Published var port = "5001"
    @Published var status = "Idle"
    @Published var isRunning = false

    let width = 1920
    let height = 1080
    let fps = 30

    private var sender: NetworkFrameSender?

    func startFromLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if let value = Self.argumentValue("--host", in: arguments) { host = value }
        if let value = Self.argumentValue("--port", in: arguments) { port = value }
        start()
    }

    func start() {
        guard let networkPort = UInt16(port), networkPort > 0 else {
            status = "Invalid network port"
            return
        }
        stop()
        do {
            let sender = NetworkFrameSender(host: host, port: networkPort, transport: .udp,
                                            source: makeSource(),
                                            width: width, height: height, fps: fps)
            try sender.start()
            self.sender = sender
            status = "Sending H.264/UDP to \(host):\(networkPort)"
            isRunning = true
        } catch {
            status = "Start failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        sender?.stop()
        sender = nil
        isRunning = false
        if status != "Idle" { status = "Stopped" }
    }

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func makeSource() -> FrameSource {
        switch input {
        case .testPattern:
            return TestPatternFrameSource(width: width, height: height, fps: fps)
        case .syphon:
            return SyphonFrameSource(width: width, height: height, fps: fps)
        }
    }
}

enum SenderInput: String, CaseIterable, Identifiable {
    case testPattern
    case syphon

    var id: Self { self }
    var label: String { self == .testPattern ? "Test Pattern" : "Syphon" }
}
