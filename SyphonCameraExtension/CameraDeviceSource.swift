import Foundation
import CoreMedia
import IOKit.audio
import CoreMediaIO
import CoreVideo

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private(set) var sourceStreamSource: SourceStreamSource!
    private(set) var sinkStreamSource: SinkStreamSource!

    private let format: CMIOExtensionStreamFormat
    private var streamingClientCount = 0
    private var lastFrame: CMSampleBuffer?
    private let lock = NSLock()

    init(localizedName: String) {
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: CameraConstants.pixelFormat,
            width: CameraConstants.width,
            height: CameraConstants.height,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            fatalError("Could not create stream format: \(status)")
        }

        format = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: CameraConstants.frameDuration,
            minFrameDuration: CameraConstants.frameDuration,
            validFrameDurations: [CameraConstants.frameDuration]
        )

        super.init()

        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: CameraConstants.deviceUUID,
            legacyDeviceID: nil,
            source: self
        )

        sourceStreamSource = SourceStreamSource(
            localizedName: CameraConstants.sourceStreamName,
            streamID: CameraConstants.sourceStreamUUID,
            streamFormat: format,
            device: device
        )

        sinkStreamSource = SinkStreamSource(
            localizedName: CameraConstants.sinkStreamName,
            streamID: CameraConstants.sinkStreamUUID,
            streamFormat: format,
            device: device
        )

        sinkStreamSource.onSampleBuffer = { [weak self] sampleBuffer, sequenceNumber in
            self?.accept(sampleBuffer, sequenceNumber: sequenceNumber)
        }

        do {
            // Keep source first and sink second. The host MVP discovers the final
            // stream as the sink; Codex should replace this with robust scope/
            // direction inspection if API support allows.
            try device.addStream(sourceStreamSource.stream)
            try device.addStream(sinkStreamSource.stream)
        } catch {
            fatalError("Failed to add camera streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            result.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            result.model = "SyphonCamera-0.1"
        }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startSourceStreaming() {
        lock.lock()
        streamingClientCount += 1
        let frame = lastFrame
        lock.unlock()

        if let frame {
            sendToClients(frame)
        }
    }

    func stopSourceStreaming() {
        lock.lock()
        streamingClientCount = max(0, streamingClientCount - 1)
        lock.unlock()
    }

    private func accept(_ sampleBuffer: CMSampleBuffer, sequenceNumber: UInt64) {
        lock.lock()
        lastFrame = sampleBuffer
        let shouldSend = streamingClientCount > 0
        lock.unlock()

        if shouldSend {
            sendToClients(sampleBuffer)
        }
    }

    private func sendToClients(_ sampleBuffer: CMSampleBuffer) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let nanos = UInt64(max(0, now.seconds) * Double(NSEC_PER_SEC))
        sourceStreamSource.stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: nanos
        )
    }
}
