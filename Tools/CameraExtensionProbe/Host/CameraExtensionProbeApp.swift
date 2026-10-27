import AppKit
import SwiftUI
import SystemExtensions

final class ActivationController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let extensionIdentifier = "com.dream-jack.syphoncamera.probe.camera"
    @Published private(set) var lines: [String] = []
    @Published private(set) var requestInProgress = false
    private var pendingRequest: OSSystemExtensionRequest?
    let logURL: URL

    override init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraExtensionProbe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("activation.log")
        super.init()
        record("Launched. Extension: \(Self.extensionIdentifier). Bundle: \(Bundle.main.bundleURL.path)")
        record("Activation log: \(logURL.path)")
    }

    func activate() { submit(activate: true) }
    func deactivate() { submit(activate: false) }

    private func submit(activate: Bool) {
        guard !requestInProgress else { record("A request is already pending."); return }
        let request = activate
            ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
            : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
        request.delegate = self
        pendingRequest = request
        requestInProgress = true
        record("Submitting \(activate ? "activation" : "deactivation") request.")
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        record("NEEDS_USER_APPROVAL: approve Dream Jack Camera Probe in System Settings.")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let outcome = result == .completed ? "COMPLETED" : "WILL_COMPLETE_AFTER_REBOOT"
        record("REQUEST_FINISHED: \(outcome), rawValue=\(result.rawValue)")
        requestInProgress = false
        pendingRequest = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let error = error as NSError
        record("REQUEST_FAILED: domain=\(error.domain), code=\(error.code), description=\(error.localizedDescription), details=\(error.userInfo)")
        requestInProgress = false
        pendingRequest = nil
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        record("Replacing probe extension \(existing.bundleShortVersion) (\(existing.bundleVersion)) with \(replacement.bundleShortVersion) (\(replacement.bundleVersion)).")
        return .replace
    }

    private func record(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)"
        lines.append(line)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let file = try? FileHandle(forWritingTo: logURL) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: data)
        }
        NSLog("%@", line)
    }
}

@main
struct CameraExtensionProbeApp: App {
    @StateObject private var controller = ActivationController()
    @State private var handledArguments = false

    var body: some Scene {
        WindowGroup("Dream Jack Camera Extension Probe") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Dream Jack Camera Extension Probe").font(.title2)
                Text("An isolated moving-pattern camera for signing and activation verification.")
                HStack {
                    Button("Activate test camera") { controller.activate() }
                    Button("Deactivate test camera") { controller.deactivate() }
                }.disabled(controller.requestInProgress)
                ScrollView {
                    Text(controller.lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(controller.logURL.path).font(.caption).textSelection(.enabled)
            }
            .padding(20)
            .frame(minWidth: 760, minHeight: 420)
            .onAppear {
                guard !handledArguments else { return }
                handledArguments = true
                if CommandLine.arguments.contains("--activate") { controller.activate() }
                else if CommandLine.arguments.contains("--deactivate") { controller.deactivate() }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
