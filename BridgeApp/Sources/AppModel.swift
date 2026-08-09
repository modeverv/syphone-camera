import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSource: SourceKind = .testPattern
    @Published var status: String = "Idle"
    @Published var isRunning: Bool = false

    // UniCamEx v1.2.0 advertises a fixed 1920x1080 BGRA stream.
    let width: Int = 1920
    let height: Int = 1080
    let fps: Int = 30

    private let engine = BridgeEngine()

    func start() {
        do {
            try engine.start(source: selectedSource, width: width, height: height, fps: fps)
            status = "Running"
            isRunning = true
        } catch {
            status = "Start failed: \(error)"
            isRunning = false
        }
    }

    func stop() {
        engine.stop()
        status = "Stopped"
        isRunning = false
    }

    func sendSingleDiagnosticFrame() {
        do {
            try engine.sendSingleDiagnosticFrame(width: width, height: height)
            status = "Sent diagnostic frame"
        } catch {
            status = "Diagnostic send failed: \(error)"
        }
    }
}

enum SourceKind {
    case testPattern
    case syphon
}
