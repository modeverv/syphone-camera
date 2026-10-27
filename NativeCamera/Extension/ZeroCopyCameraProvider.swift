import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import IOSurface
import os.log

private let cameraName = "Syphon Zero Copy Camera"
private let frameDuration = CMTime(value: 1, timescale: 30)
// Indices are part of the host/extension format-selection contract.
private let videoDimensions: [CMVideoDimensions] = [
    CMVideoDimensions(width: 1920, height: 1080),
    CMVideoDimensions(width: 1280, height: 720),
]
private let telemetryProperty = CMIOExtensionProperty(rawValue: "4cc_zcpy_glob_0000")
private let cameraLog = OSLog(subsystem: "com.dream-jack.syphoncamera.native", category: "extension")

private func extensionError(_ message: String) -> NSError {
    NSError(domain: "SyphonZeroCopyCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private struct FrameTrace: Codable {
    let surfaceID: UInt32
    let ptsValue: Int64
    let ptsTimescale: Int32
    let sinkSequence: UInt64
    let forwarded: Bool
    let formatIndex: Int
    let width: Int32
    let height: Int32
}

// All state and CMIO source callbacks belong to the provider's serial clientQueue.
// consumeSampleBuffer's completion may run elsewhere and is explicitly marshalled.
final class ZeroCopyCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: ZeroCopyCameraStreamSource!
    private var sink: ZeroCopyCameraStreamSource!
    private let clientQueue: DispatchQueue

    private var sourceClients = 0
    private var producer: CMIOExtensionClient?
    private var sinkActive = false
    private var sinkEndOfData = false
    private var generation: UInt64 = 0
    private var pendingConsume: UUID?
    private var lastPTS: CMTime?
    // Both streams use one device-native format. This prevents independently
    // negotiated source/sink indices from silently describing different images.
    fileprivate private(set) var activeFormatIndex = 0
    private var formatChanges: UInt64 = 0

    private var received: UInt64 = 0
    private var forwarded: UInt64 = 0
    private var rejected: UInt64 = 0
    private var droppedNoConsumers: UInt64 = 0
    private var consumeErrors: UInt64 = 0
    private var emptyConsumes: UInt64 = 0
    private var lastError: String = ""
    private var trace: [FrameTrace] = []
    private var traceNext = 0
    private var lastTelemetryNotification: UInt64 = 0

    init(clientQueue: DispatchQueue) {
        self.clientQueue = clientQueue
        super.init()
        trace.reserveCapacity(128)
        device = CMIOExtensionDevice(
            localizedName: cameraName,
            deviceID: UUID(uuidString: "39E62DD8-C36C-4495-9928-872C6B7B597A")!,
            legacyDeviceID: nil,
            source: self
        )
        let formats = videoDimensions.map { dimensions -> CMIOExtensionStreamFormat in
            var description: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCVPixelFormatType_32BGRA,
                width: dimensions.width,
                height: dimensions.height,
                extensions: nil,
                formatDescriptionOut: &description
            )
            guard status == noErr, let description else {
                fatalError("Cannot create camera format: \(status)")
            }
            return CMIOExtensionStreamFormat(
                formatDescription: description,
                maxFrameDuration: frameDuration,
                minFrameDuration: frameDuration,
                validFrameDurations: nil
            )
        }
        source = ZeroCopyCameraStreamSource(
            deviceSource: self,
            name: "\(cameraName).Video",
            id: UUID(uuidString: "6D18784A-7C8E-41C1-B8BC-356BE108EBBE")!,
            direction: .source,
            formats: formats
        )
        sink = ZeroCopyCameraStreamSource(
            deviceSource: self,
            name: "\(cameraName).Video.Sink",
            id: UUID(uuidString: "597D5885-3544-43EC-A4D4-501052A4821D")!,
            direction: .sink,
            formats: formats
        )
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Cannot add camera streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, telemetryProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "Syphon IOSurface Pass-through" }
        if properties.contains(telemetryProperty) {
            result.setPropertyState(telemetryState(), forProperty: telemetryProperty)
        }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        if deviceProperties.propertiesDictionary[telemetryProperty] != nil {
            throw extensionError("Zero-copy telemetry is read-only.")
        }
    }

    fileprivate func authorizeProducer(_ client: CMIOExtensionClient) -> Bool {
        if let producer, producer.clientID != client.clientID { return false }
        producer = client
        return true
    }

    fileprivate func selectFormat(index: Int) throws {
        guard videoDimensions.indices.contains(index) else {
            throw extensionError("Supported format indices are 0 (1920x1080) and 1 (1280x720), both BGRA at 30 fps.")
        }
        guard index != activeFormatIndex else { return }
        // Format changes affect every consumer. Require both streams to stop
        // before changing resolution; never resize or relabel an in-flight frame.
        guard !sinkActive, sourceClients == 0,
              source.stream.streamingClients.isEmpty,
              sink.stream.streamingClients.isEmpty else {
            throw extensionError("Stop the producer and all camera consumers before changing resolution.")
        }
        activeFormatIndex = index
        formatChanges &+= 1
        lastPTS = nil
        let changed: [CMIOExtensionProperty: CMIOExtensionPropertyState<AnyObject>] = [
            .streamActiveFormatIndex: CMIOExtensionPropertyState(value: NSNumber(value: index))
        ]
        source.stream.notifyPropertiesChanged(changed)
        sink.stream.notifyPropertiesChanged(changed)
        publishTelemetry(force: true)
    }

    fileprivate func startSource() {
        sourceClients += 1
        publishTelemetry(force: true)
    }

    fileprivate func stopSource() {
        sourceClients = max(0, sourceClients - 1)
        publishTelemetry(force: true)
    }

    fileprivate func startSink() throws {
        guard producer != nil else { throw extensionError("No authorized sink producer.") }
        guard !sinkActive else { return }
        generation &+= 1
        sinkActive = true
        sinkEndOfData = false
        lastPTS = nil
        publishTelemetry(force: true)
        requestNextBuffer()
    }

    fileprivate func stopSink() {
        sinkActive = false
        sinkEndOfData = true
        generation &+= 1
        producer = nil
        lastPTS = nil
        // No public cancellation API exists. Keep the pending token until its
        // completion arrives, so stop/start cannot issue concurrent consumes.
        publishTelemetry(force: true)
    }

    func disconnected(_ client: CMIOExtensionClient) {
        if producer?.clientID == client.clientID { stopSink() }
    }

    fileprivate func setEndOfData(_ value: Bool) {
        sinkEndOfData = value
        if !value { requestNextBuffer() }
        publishTelemetry(force: true)
    }

    fileprivate var endOfData: Bool { sinkEndOfData }
    fileprivate var underrunCount: UInt64 { emptyConsumes }

    private func requestNextBuffer(after delay: DispatchTimeInterval = .nanoseconds(0)) {
        guard sinkActive, !sinkEndOfData, pendingConsume == nil, let producer else { return }
        let requestGeneration = generation
        // Always enqueue the next operation to prevent synchronous-recursion
        // growth even if CMIO happens to complete a request inline.
        clientQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.sinkActive,
                  !self.sinkEndOfData,
                  self.generation == requestGeneration,
                  self.pendingConsume == nil,
                  self.producer?.clientID == producer.clientID else { return }
            let token = UUID()
            self.pendingConsume = token
            self.sink.stream.consumeSampleBuffer(from: producer) { [weak self] sample, sequence, discontinuity, _, error in
                guard let self else { return }
                // Capturing sample strongly keeps its image buffer alive until
                // forwarding has run on the serial queue.
                self.clientQueue.async {
                    guard self.pendingConsume == token else { return }
                    self.pendingConsume = nil
                    guard self.sinkActive, self.generation == requestGeneration else {
                        self.requestNextBuffer()
                        return
                    }
                    if let error {
                        self.consumeErrors &+= 1
                        self.lastError = error.localizedDescription
                        self.publishTelemetry(force: true)
                        self.requestNextBuffer(after: .milliseconds(100))
                        return
                    }
                    guard let sample else {
                        self.emptyConsumes &+= 1
                        self.requestNextBuffer(after: .milliseconds(5))
                        return
                    }
                    self.consume(sample, sequence: sequence, discontinuity: discontinuity)
                    self.requestNextBuffer()
                }
            }
        }
    }

    private func consume(_ sample: CMSampleBuffer, sequence: UInt64,
                         discontinuity: CMIOExtensionStream.DiscontinuityFlags) {
        received &+= 1
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        defer {
            // Acknowledges consumption/output scheduling only. It is NOT a
            // signal that every downstream process has released the IOSurface.
            sink.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(
                sequenceNumber: sequence,
                hostTimeInNanoseconds: UInt64(max(0, CMTimeConvertScale(now, timescale: 1_000_000_000, method: .default).value))
            ))
            publishTelemetry(force: false)
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dimensions = videoDimensions[activeFormatIndex]
        guard let image = CMSampleBufferGetImageBuffer(sample),
              let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else {
            reject("Input has no IOSurface-backed pixel buffer.")
            return
        }
        guard let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaSubType(description) == kCVPixelFormatType_32BGRA,
              CMVideoFormatDescriptionGetDimensions(description).width == dimensions.width,
              CMVideoFormatDescriptionGetDimensions(description).height == dimensions.height,
              CVPixelBufferGetWidth(image) == Int(dimensions.width),
              CVPixelBufferGetHeight(image) == Int(dimensions.height),
              CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
              IOSurfaceGetWidth(surface) == Int(dimensions.width),
              IOSurfaceGetHeight(surface) == Int(dimensions.height),
              IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_32BGRA,
              CMSampleBufferGetNumSamples(sample) == 1,
              CMSampleBufferDataIsReady(sample),
              pts.isNumeric,
              pts.value >= 0 else {
            reject("Input must match the selected \(dimensions.width)x\(dimensions.height) BGRA format and contain one ready IOSurface frame with a valid nonnegative timestamp.")
            return
        }
        if let lastPTS, CMTimeCompare(pts, lastPTS) <= 0 {
            reject("Input timestamps must increase monotonically within a producer session.")
            return
        }
        let hostTime = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default)
        guard hostTime.isNumeric, hostTime.value >= 0 else {
            reject("Timestamp conversion overflow.")
            return
        }
        lastPTS = pts
        let hasConsumers = sourceClients > 0
        let surfaceID = IOSurfaceGetID(surface)
        appendTrace(FrameTrace(surfaceID: surfaceID, ptsValue: pts.value,
                               ptsTimescale: pts.timescale, sinkSequence: sequence,
                               forwarded: hasConsumers, formatIndex: activeFormatIndex,
                               width: dimensions.width, height: dimensions.height))
        guard hasConsumers else {
            droppedNoConsumers &+= 1
            return
        }
        // The incoming CMSampleBuffer itself is forwarded. There is no new
        // CVPixelBuffer, CPU readback, pixel memcpy, GPU render, or GPU blit.
        source.stream.send(sample, discontinuity: discontinuity, hostTimeInNanoseconds: UInt64(hostTime.value))
        forwarded &+= 1
        os_log(.debug, log: cameraLog,
               "ZC_FRAME surface=%{public}u pts=%{public}lld/%{public}d sinkSequence=%{public}llu extensionPixelCopies=0",
               surfaceID, pts.value, pts.timescale, sequence)
    }

    private func reject(_ reason: String) {
        rejected &+= 1
        lastError = reason
        if rejected == 1 || rejected % 30 == 0 {
            os_log(.error, log: cameraLog, "ZC_REJECT %{public}@", reason)
        }
    }

    private func appendTrace(_ item: FrameTrace) {
        if trace.count < 128 { trace.append(item) }
        else { trace[traceNext] = item }
        traceNext = (traceNext + 1) % 128
    }

    fileprivate func telemetryState() -> CMIOExtensionPropertyState<AnyObject> {
        let frames: [FrameTrace]
        if trace.count < 128 { frames = trace }
        else { frames = Array(trace[traceNext...] + trace[..<traceNext]) }
        let frameJSON = frames.map { item -> [String: Any] in
            ["surfaceID": item.surfaceID, "ptsValue": item.ptsValue,
             "ptsTimescale": item.ptsTimescale, "sinkSequence": item.sinkSequence,
             "forwarded": item.forwarded, "formatIndex": item.formatIndex,
             "width": item.width, "height": item.height]
        }
        let dimensions = videoDimensions[activeFormatIndex]
        let snapshot: [String: Any] = [
            "schemaVersion": 1, "path": "SAME_CMSAMPLEBUFFER", "received": received,
            "forwarded": forwarded, "rejected": rejected,
            "droppedNoConsumers": droppedNoConsumers, "consumeErrors": consumeErrors,
            "emptyConsumes": emptyConsumes, "sourceClients": sourceClients,
            "sinkActive": sinkActive, "consumePending": pendingConsume != nil,
            "sinkEndOfData": sinkEndOfData, "generation": generation,
            "lastError": lastError, "extensionPixelCopyOperations": 0,
            "activeFormatIndex": activeFormatIndex, "sourceActiveFormatIndex": activeFormatIndex,
            "sinkActiveFormatIndex": activeFormatIndex, "width": dimensions.width,
            "height": dimensions.height, "frameRate": 30, "formatChanges": formatChanges,
            "recentFrames": frameJSON
        ]
        let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":\"telemetry encoding failed\"}"
        return CMIOExtensionPropertyState(value: json as NSString,
                                          attributes: CMIOExtensionPropertyAttributes<AnyObject>.readOnlyPropertyAttribute)
    }

    private func publishTelemetry(force: Bool) {
        guard force || received &- lastTelemetryNotification >= 30 else { return }
        lastTelemetryNotification = received
        let changed = [telemetryProperty: telemetryState()]
        device.notifyPropertiesChanged(changed)
        source.stream.notifyPropertiesChanged(changed)
        sink.stream.notifyPropertiesChanged(changed)
        os_log(.info, log: cameraLog,
               "ZC_STATE received=%{public}llu forwarded=%{public}llu rejected=%{public}llu noConsumers=%{public}llu clients=%{public}d sink=%{public}d copies=0",
               received, forwarded, rejected, droppedNoConsumers, sourceClients, sinkActive ? 1 : 0)
    }
}

private final class ZeroCopyCameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let deviceSource: ZeroCopyCameraDeviceSource
    private let direction: CMIOExtensionStream.Direction
    let formats: [CMIOExtensionStreamFormat]

    init(deviceSource: ZeroCopyCameraDeviceSource, name: String, id: UUID,
         direction: CMIOExtensionStream.Direction, formats: [CMIOExtensionStreamFormat]) {
        self.deviceSource = deviceSource
        self.direction = direction
        self.formats = formats
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: direction,
                                     clockType: .hostTime, source: self)
    }

    var activeFormatIndex: Int { deviceSource.activeFormatIndex }
    var availableProperties: Set<CMIOExtensionProperty> {
        var result: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration,
                                                  .streamMaxFrameDuration, telemetryProperty]
        if direction == .sink {
            result.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
                              .streamSinkBufferUnderrunCount, .streamSinkEndOfData])
        }
        return result
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = activeFormatIndex }
        if properties.contains(.streamFrameDuration) { result.frameDuration = frameDuration }
        if properties.contains(.streamMaxFrameDuration) { result.maxFrameDuration = frameDuration }
        if properties.contains(telemetryProperty) {
            result.setPropertyState(deviceSource.telemetryState(), forProperty: telemetryProperty)
        }
        if direction == .sink {
            if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 1 }
            if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
            if properties.contains(.streamSinkBufferUnderrunCount) { result.sinkBufferUnderrunCount = Int(clamping: deviceSource.underrunCount) }
            if properties.contains(.streamSinkEndOfData) { result.sinkEndOfData = deviceSource.endOfData ? 1 : 0 }
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        for duration in [streamProperties.frameDuration, streamProperties.maxFrameDuration].compactMap({ $0 }) {
            guard duration.isNumeric, CMTimeCompare(duration, frameDuration) == 0 else {
                throw extensionError("The supported frame rate is 30 fps.")
            }
        }
        if streamProperties.propertiesDictionary[telemetryProperty] != nil {
            throw extensionError("Zero-copy telemetry is read-only.")
        }
        if let index = streamProperties.activeFormatIndex {
            try deviceSource.selectFormat(index: index)
        }
        if direction == .sink, let end = streamProperties.sinkEndOfData {
            deviceSource.setEndOfData(end != 0)
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        direction == .source || deviceSource.authorizeProducer(client)
    }

    func startStream() throws {
        if direction == .source { deviceSource.startSource() }
        else { try deviceSource.startSink() }
    }

    func stopStream() throws {
        if direction == .source { deviceSource.stopSource() }
        else { deviceSource.stopSink() }
    }
}

final class ZeroCopyCameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var camera: ZeroCopyCameraDeviceSource!

    init(clientQueue: DispatchQueue) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        camera = ZeroCopyCameraDeviceSource(clientQueue: clientQueue)
        do { try provider.addDevice(camera.device) }
        catch { fatalError("Cannot publish camera: \(error)") }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) { camera.disconnected(client) }
    var availableProperties: Set<CMIOExtensionProperty> { [.providerName, .providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerName) { result.name = cameraName }
        if properties.contains(.providerManufacturer) { result.manufacturer = "Dream Jack Inc." }
        return result
    }
    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
