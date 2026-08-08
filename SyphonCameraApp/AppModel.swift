import Foundation
import Metal
import CoreMedia
import CoreVideo

@MainActor
final class AppModel: ObservableObject {
    enum InputMode: String, CaseIterable, Identifiable {
        case testPattern = "Test Pattern"
        case syphon = "Syphon"
        var id: String { rawValue }
    }

    @Published var status = "Idle"
    @Published var inputMode: InputMode = .testPattern
    @Published var syphonServers: [String] = []
    @Published var selectedSyphonServer: String?
    @Published var syphonNameFilter = "Webcam"
    @Published var isRunning = false

    private let extensionManager = CameraExtensionManager()
    private var sinkWriter: CMIOSinkWriter?
    private var testPattern: TestPatternSource?
    private var syphonSource: SyphonFrameSource?
    private var converter: MetalFrameConverter?

    init() {
        extensionManager.onStatus = { [weak self] message in
            Task { @MainActor in self?.status = message }
        }
    }

    func activateExtension() {
        extensionManager.activate()
    }

    func refreshSyphonServers() {
        syphonServers = SyphonFrameSource.availableServerDisplayNames()
        if selectedSyphonServer == nil {
            selectedSyphonServer = syphonServers.first {
                syphonNameFilter.isEmpty ||
                $0.localizedCaseInsensitiveContains(syphonNameFilter)
            } ?? syphonServers.first
        }
    }

    func toggleBridge() {
        isRunning ? stopBridge() : startBridge()
    }

    private func startBridge() {
        do {
            let writer = CMIOSinkWriter(cameraName: CameraConstants.cameraName)
            try writer.open()
            sinkWriter = writer

            switch inputMode {
            case .testPattern:
                let source = TestPatternSource()
                source.onFrame = { [weak self] pixelBuffer, pts in
                    guard let sample = SampleBufferFactory.make(
                        pixelBuffer: pixelBuffer,
                        presentationTime: pts
                    ) else { return }
                    self?.sinkWriter?.enqueue(sample)
                }
                try source.start()
                testPattern = source
                status = "Streaming test pattern → \(CameraConstants.cameraName)"

            case .syphon:
                guard let device = MTLCreateSystemDefaultDevice() else {
                    throw NSError(domain: "SyphonCamera", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "No Metal device"])
                }
                converter = try MetalFrameConverter(device: device)

                let source = SyphonFrameSource(device: device)
                source.onTexture = { [weak self] texture, pts in
                    guard let self else { return }
                    do {
                        let pb = try self.converter?.convert(texture)
                        guard let pb,
                              let sample = SampleBufferFactory.make(
                                pixelBuffer: pb,
                                presentationTime: pts
                              ) else { return }
                        self.sinkWriter?.enqueue(sample)
                    } catch {
                        Task { @MainActor in
                            self.status = "Frame conversion error: \(error)"
                        }
                    }
                }

                try source.start(displayName: selectedSyphonServer)
                syphonSource = source
                status = "Streaming Syphon → \(CameraConstants.cameraName)"
            }

            isRunning = true
        } catch {
            stopBridge()
            status = "Start failed: \(error.localizedDescription)"
        }
    }

    private func stopBridge() {
        testPattern?.stop()
        testPattern = nil
        syphonSource?.stop()
        syphonSource = nil
        converter = nil
        sinkWriter?.close()
        sinkWriter = nil
        isRunning = false
        status = "Stopped"
    }
}
