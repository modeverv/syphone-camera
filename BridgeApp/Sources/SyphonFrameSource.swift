import Foundation
import CoreMedia
import Metal
import os.log
import Syphon

final class SyphonFrameSource: FrameSource {
    private let width: Int
    private let height: Int
    private let fps: Int
    private let store = LatestFrameStore()
    private let fallback: TestPatternFrameSource
    private var client: SyphonMetalClient?
    private var device: MTLDevice?

    var isActive: Bool = false

    init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.fallback = TestPatternFrameSource(width: width, height: height, fps: fps)
    }

    func start() throws {
        isActive = true
        device = MTLCreateSystemDefaultDevice()
        let directory = SyphonServerDirectory.shared()
        let servers = directory.servers
        os_log("Syphon servers: %{public}@", servers.map { description in
            let name = description[SyphonServerDescriptionNameKey] as? String ?? ""
            let app = description[SyphonServerDescriptionAppNameKey] as? String ?? ""
            return "\(app)/\(name)"
        }.joined(separator: ", "))
        let preferred = servers.first { description in
            let name = description[SyphonServerDescriptionNameKey] as? String ?? ""
            let app = description[SyphonServerDescriptionAppNameKey] as? String ?? ""
            return name.localizedCaseInsensitiveContains("Webcam Motion Receiver") ||
                app.localizedCaseInsensitiveContains("Webcam Motion Capture")
        } ?? servers.first
        if let preferred, let device {
            os_log("Syphon selected: %{public}@", (preferred[SyphonServerDescriptionNameKey] as? String) ?? "(unnamed)")
            let candidate = SyphonMetalClient(serverDescription: preferred, device: device, options: nil) { [weak self] client in
                guard let self, let texture = client.newFrameImage() else { return }
                if self.store.currentTexture() == nil {
                    os_log("Syphon texture: %{public}dx%{public}d iosurface=%{public}@", texture.width, texture.height, texture.iosurface == nil ? "no" : "yes")
                }
                PipelineInstrumentation.event("SyphonFrameReceived")
                self.store.publish(texture: texture)
            }
            if candidate.isValid {
                client = candidate
            } else {
                try fallback.start()
            }
        } else {
            os_log("Syphon source unavailable; using diagnostic fallback")
            try fallback.start()
        }
    }

    func stop() {
        client?.stop()
        client = nil
        fallback.stop()
        isActive = false
    }

    func latestTexture() -> MTLTexture? { store.currentTexture() }
    var latestTexturePublishedAt: UInt64? { store.currentTexturePublishedAt() }
    func latestSampleBuffer() -> CMSampleBuffer? {
        if let sampleBuffer = store.currentSampleBuffer() { return sampleBuffer }
        return fallback.latestSampleBuffer()
    }
}
