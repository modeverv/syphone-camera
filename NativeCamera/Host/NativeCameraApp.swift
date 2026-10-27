import AppKit
import SwiftUI
import SystemExtensions
import Syphon

final class CameraController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let shared = CameraController()
    @Published var status = "カメラ拡張を有効化して入力を開始してください。"
    @Published var activationStatus = ""
    @Published var syphonReport = ""
    @Published var activationPending = false
    @Published var resolution = "1080p"
    let directory: URL
    let engine: NativeCameraEngine
    private var request: OSSystemExtensionRequest?
    private var startAfterActivation = false
    private var patternDuration: Double?
    private var patternMode: SurfacePatternRenderer.TransportMode = .zeroCopy
    private var benchmarkMode = false
    private var handledArguments = false
    private var useSyphon = false

    override init() {
        // Keep diagnostic artifacts at the same location as builds 1–4.
        // The host is not sandboxed because Syphon uses dynamic Mach ports;
        // the Camera Extension remains sandboxed.
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.dream-jack.syphoncamera.probe/Data/Library/Application Support/SyphonZeroCopyCamera", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        engine = NativeCameraEngine(directory: directory)
        super.init()
        engine.statusChanged = { [weak self] in self?.status = $0 }
        try? Data().write(to: directory.appendingPathComponent("activation.log"))
    }

    func handleLaunchArguments() {
        guard !handledArguments else { return }; handledArguments = true
        let args = CommandLine.arguments
        _ = SyphonServerDirectory.shared()
        if let index = args.firstIndex(of: "--source") {
            guard index + 1 < args.count, ["pattern", "syphon"].contains(args[index + 1]) else {
                status = "--source は pattern または syphon を指定してください。"; return
            }
            useSyphon = args[index + 1] == "syphon"
        }
        if let index = args.firstIndex(of: "--resolution") {
            guard index + 1 < args.count, ["1080p", "720p"].contains(args[index + 1]) else {
                status = "--resolution は 1080p または 720p を指定してください。"; return
            }
            resolution = args[index + 1]
        }
        if let index = args.firstIndex(of: "--transport") {
            guard index + 1 < args.count, let mode = SurfacePatternRenderer.TransportMode(rawValue: args[index + 1]) else {
                status = "--transport は zero-copy または gpu-copy を指定してください。"; return
            }
            patternMode = mode
        }
        benchmarkMode = args.contains("--benchmark")
        var duration: Double?
        if let index = args.firstIndex(of: "--duration"), index + 1 < args.count,
           let seconds = Double(args[index + 1]), seconds > 0, seconds.isFinite {
            duration = seconds
        }
        if useSyphon && patternMode != .zeroCopy {
            status = "--transport gpu-copy はテスト映像専用です。"; return
        }
        if args.contains("--activate") { activate(startPattern: args.contains("--test-pattern") || useSyphon, duration: duration) }
        else if useSyphon {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startSyphon(duration: duration) }
        } else if args.contains("--test-pattern") {
            startPattern(duration: duration)
        }
    }

    func startPattern(duration: Double? = nil) {
        engine.startPattern(duration: duration, mode: patternMode, benchmark: benchmarkMode,
                            width: resolution == "720p" ? 1280 : 1920,
                            height: resolution == "720p" ? 720 : 1080)
    }

    func startSyphon(duration: Double? = nil) {
        engine.startSyphon(duration: duration, benchmark: benchmarkMode,
                          width: resolution == "720p" ? 1280 : 1920,
                          height: resolution == "720p" ? 720 : 1080)
    }

    func activate(startPattern: Bool = false, duration: Double? = nil) {
        guard !activationPending else { return }
        startAfterActivation = startPattern
        patternDuration = duration
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:
            "com.dream-jack.syphoncamera.probe.camera", queue: .main)
        request.delegate = self; self.request = request; activationPending = true
        record("ACTIVATION_REQUESTED")
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) { record("NEEDS_USER_APPROVAL") }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        activationPending = false; self.request = nil
        record(result == .completed ? "COMPLETED" : "WILL_COMPLETE_AFTER_REBOOT")
        if result == .completed, startAfterActivation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                if self.useSyphon { self.startSyphon(duration: self.patternDuration) }
                else { self.startPattern(duration: self.patternDuration) }
            }
        }
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        activationPending = false; self.request = nil
        record("FAILED: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        record("REPLACE: \(existing.bundleVersion) -> \(replacement.bundleVersion)")
        return .replace
    }
    func diagnoseSyphon() { syphonReport = SyphonDirectSource.diagnosticReport() }
    private func record(_ message: String) {
        activationStatus = message
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: directory.appendingPathComponent("activation.log")) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(text.utf8))
        }
    }
}

final class NativeCameraAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CameraController.shared.handleLaunchArguments()
    }
    func applicationWillTerminate(_ notification: Notification) {
        CameraController.shared.engine.shutdown()
    }
}

@main
struct NativeCameraApp: App {
    @NSApplicationDelegateAdaptor(NativeCameraAppDelegate.self) private var delegate
    @StateObject private var controller = CameraController.shared
    var body: some Scene {
        WindowGroup("Syphon Zero Copy Camera") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Syphon Zero Copy Camera").font(.title)
                Text("30 fps · BGRA · 1080p / 720p").foregroundStyle(.secondary)
                HStack {
                    Button("カメラ拡張を有効化・更新") { controller.activate() }.disabled(controller.activationPending)
                    Text(controller.activationStatus).font(.caption)
                }
                Divider()
                Text("コピーしない転送経路を検証").font(.headline)
                Picker("出力解像度", selection: $controller.resolution) {
                    Text("1080p (1920 × 1080)").tag("1080p")
                    Text("720p (1280 × 720)").tag("720p")
                }.pickerStyle(.segmented)
                Text("解像度を切り替えるときは、受信アプリのカメラと送信を停止してから再開してください。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("WMC映像を開始") { controller.startSyphon() }
                    Button("GPUテスト映像を開始") { controller.startPattern() }
                    Button("停止") { controller.engine.stop() }
                }
                Text(controller.status).textSelection(.enabled)
                Text("WMC入力はGPUで1回縮小・上下反転し、そのバッファを拡張へ共有します。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("受信アプリで「Syphon Zero Copy Camera」を選択すると映像を受け取れます。")
                Divider()
                Button("Syphon入力の対応状況を確認") { controller.diagnoseSyphon() }
                if !controller.syphonReport.isEmpty {
                    ScrollView { Text(controller.syphonReport).font(.caption).textSelection(.enabled) }.frame(maxHeight: 140)
                }
                Text("検証記録: \(controller.directory.path)").font(.caption).textSelection(.enabled)
            }
            .padding(24).frame(minWidth: 760, minHeight: 410)
        }
    }
}
