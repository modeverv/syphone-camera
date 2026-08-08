import Foundation
import CoreMedia
import CoreMediaIO

final class SinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    private let device: CMIOExtensionDevice
    private var client: CMIOExtensionClient?
    private var running = false

    var onSampleBuffer: ((CMSampleBuffer, UInt64) -> Void)?

    init(
        localizedName: String,
        streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice
    ) {
        self.streamFormat = streamFormat
        self.device = device
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex != 0 { activeFormatIndex = 0 }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex,
            .streamFrameDuration,
            .streamSinkBufferQueueSize,
            .streamSinkBuffersRequiredForStartup
        ]
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            result.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = CameraConstants.frameDuration
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            result.sinkBufferQueueSize = 1
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            result.sinkBuffersRequiredForStartup = 1
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let idx = streamProperties.activeFormatIndex {
            activeFormatIndex = idx
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        running = true
        subscribe()
    }

    func stopStream() throws {
        running = false
        client = nil
    }

    private func subscribe() {
        guard running, let client else { return }

        stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer,
                                                     sequenceNumber,
                                                     discontinuity,
                                                     hasMore,
                                                     error in
            guard let self else { return }
            defer {
                if self.running {
                    self.subscribe()
                }
            }

            guard error == nil, let sampleBuffer else { return }

            self.onSampleBuffer?(sampleBuffer, sequenceNumber)

            let pts = sampleBuffer.presentationTimeStamp
            let nanos: UInt64
            if pts.isValid && pts.seconds.isFinite && pts.seconds >= 0 {
                nanos = UInt64(pts.seconds * Double(NSEC_PER_SEC))
            } else {
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                nanos = UInt64(max(0, now.seconds) * Double(NSEC_PER_SEC))
            }

            let output = CMIOExtensionScheduledOutput(
                sequenceNumber: sequenceNumber,
                hostTimeInNanoseconds: nanos
            )
            self.stream.notifyScheduledOutputChanged(output)
        }
    }
}
