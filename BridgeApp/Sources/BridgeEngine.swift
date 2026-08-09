import Foundation
import Metal
import CoreMedia
import os

final class BridgeEngine {
    private var source: FrameSource?
    private let sender: UniCamExSending
    private let timerQueue = DispatchQueue(label: "local.syphon-unicamex.bridge.timer")
    private var timer: DispatchSourceTimer?
    private var loggedSampleEnqueue = false

    init(sender: UniCamExSending = UniCamExSender()) {
        self.sender = sender
    }

    func start(source kind: SourceKind, width: Int, height: Int, fps: Int, networkPort: UInt16 = 5000, networkTransport: NetworkTransport = .tcp) throws {
        stop()

        let newSource: FrameSource
        switch kind {
        case .testPattern:
            newSource = TestPatternFrameSource(width: width, height: height, fps: fps)
        case .syphon:
            newSource = SyphonFrameSource(width: width, height: height, fps: fps)
        case .network:
            newSource = NetworkFrameSource(width: width, height: height, fps: fps, port: networkPort, transport: networkTransport)
        }

        try newSource.start()
        source = newSource

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        let interval = DispatchTimeInterval.milliseconds(max(1, 1000 / max(1, fps)))
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        source?.stop()
        source = nil
    }

    func sendSingleDiagnosticFrame(width: Int, height: Int) throws {
        let temp = TestPatternFrameSource(width: width, height: height, fps: 30)
        try temp.start()
        defer { temp.stop() }
        if let texture = temp.latestTexture() {
            try sender.send(texture: texture)
        } else if let sampleBuffer = temp.latestSampleBuffer() {
            try sender.send(sampleBuffer: sampleBuffer)
        } else {
            throw BridgeError.noFrameAvailable
        }
    }

    private func tick() {
        guard let source else { return }
        do {
            if let texture = source.latestTexture() {
                if let publishedAt = source.latestTexturePublishedAt {
                    sender.recordTextureLatency(milliseconds: PipelineInstrumentation.elapsedMilliseconds(since: publishedAt))
                }
                try sender.send(texture: texture)
                return
            }
            if let sampleBuffer = source.latestSampleBuffer() {
                try sender.send(sampleBuffer: sampleBuffer)
                if !loggedSampleEnqueue {
                    loggedSampleEnqueue = true
                    os_log("BridgeEngine offered first decoded sample buffer to UniCamEx")
                }
                return
            }
        } catch {
            os_log("BridgeEngine frame submission failed: %{public}@", error.localizedDescription)
        }
    }
}
