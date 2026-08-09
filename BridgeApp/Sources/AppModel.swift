import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSource: SourceKind = .testPattern
    @Published var status: String = "Idle"
    @Published var isRunning: Bool = false
    @Published var networkPort: String = "5001"
    @Published var networkHost: String = "127.0.0.1"

    // UniCamEx v1.2.0 advertises a fixed 1920x1080 BGRA stream.
    let width: Int = 1920
    let height: Int = 1080
    let fps: Int = 30

    private var engine: BridgeEngine?
    private var loopbackSender: NetworkFrameSender?
    private var networkTransport: NetworkTransport = .tcp

    private func bridgeEngine() -> BridgeEngine {
        if let engine { return engine }
        let engine = BridgeEngine()
        self.engine = engine
        return engine
    }

    func start() {
        do {
            guard let port = UInt16(networkPort), port > 0 else {
                throw NSError(domain: "Network", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid network port"])
            }
            try bridgeEngine().start(source: selectedSource, width: width, height: height, fps: fps, networkPort: port, networkTransport: networkTransport)
            status = "Running"
            isRunning = true
        } catch {
            status = "Start failed: \(error)"
            isRunning = false
        }
    }

    func stop() {
        loopbackSender?.stop()
        loopbackSender = nil
        engine?.stop()
        engine = nil
        status = "Stopped"
        isRunning = false
    }

    func runNetworkLoopback() {
        do {
            let port = UInt16(networkPort) ?? 5000
            try bridgeEngine().start(source: .network, width: width, height: height, fps: fps, networkPort: port, networkTransport: networkTransport)
            let sender = NetworkFrameSender(host: "127.0.0.1", port: port,
                                            transport: networkTransport,
                                            source: TestPatternFrameSource(width: width, height: height, fps: fps),
                                            width: width, height: height, fps: fps)
            try sender.start()
            loopbackSender = sender
            selectedSource = .network
            status = "Network loopback running"
            isRunning = true
        } catch {
            loopbackSender?.stop()
            loopbackSender = nil
            engine?.stop()
            engine = nil
            status = "Loopback failed: \(error)"
            isRunning = false
        }
    }

    func sendSingleDiagnosticFrame() {
        do {
            try bridgeEngine().sendSingleDiagnosticFrame(width: width, height: height)
            status = "Sent diagnostic frame"
        } catch {
            status = "Diagnostic send failed: \(error)"
        }
    }

    /// Makes `open -n ... --args --receiver|--sender` useful for LAN testing
    /// without starting the unrelated UniCamEx output path in the sender process.
    func startFromLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let mode = arguments.first(where: { $0 == "--receiver" || $0 == "--sender" }) else { return }
        let port = Self.argumentValue("--port", in: arguments).flatMap(UInt16.init) ?? 5001
        networkTransport = NetworkTransport(rawValue: Self.argumentValue("--transport", in: arguments) ?? "tcp") ?? .tcp
        networkPort = String(port)
        if mode == "--receiver" {
            selectedSource = .network
            start()
            status = isRunning ? "TCP H.264 receiver running on port \\(port)" : status
            return
        }

        let host = Self.argumentValue("--host", in: arguments) ?? networkHost
        networkHost = host
        do {
            let sender = NetworkFrameSender(host: host, port: port,
                                            transport: networkTransport,
                                            source: TestPatternFrameSource(width: width, height: height, fps: fps),
                                            width: width, height: height, fps: fps)
            try sender.start()
            loopbackSender = sender
            status = "TCP H.264 sender running to \\(host):\\(port)"
            isRunning = true
        } catch {
            status = "Sender start failed: \\(error)"
            isRunning = false
        }
    }

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
