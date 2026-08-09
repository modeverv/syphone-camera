import AVFoundation
import CoreImage
import CoreMedia
import CoreMediaIO
import Foundation
import Metal
import os.log

final class UniCamExSender: UniCamExSending {
    private var streamQueue: CMSimpleQueue?
    private var deviceID: CMIODeviceID = 0
    private var streamID: CMIOStreamID = 0
    private let stateLock = NSLock()
    private var shouldEnqueue = false
    private var sendCount = 0
    private var droppedCount = 0
    private var latencyTotalMs = 0.0
    private var latencySamples = 0
    private var networkLatencyTotalMs = 0.0
    private var networkLatencySamples = 0
    private let ciContext: CIContext?
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private var pixelBufferPool: CVPixelBufferPool?

    private let outputWidth = 1920
    private let outputHeight = 1080

    init() {
        ciContext = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0) }
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &pool)
        pixelBufferPool = pool
        connect()
    }

    func send(texture: MTLTexture) throws {
        guard let streamQueue else { throw BridgeError.uniCamExUnavailable }
        stateLock.lock()
        guard shouldEnqueue else {
            droppedCount += 1
            stateLock.unlock()
            return
        }
        shouldEnqueue = false
        stateLock.unlock()

        var pixelBuffer: CVPixelBuffer?
        guard let pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer,
              let ciContext else { return }
        let image = CIImage(mtlTexture: texture, options: [.colorSpace: sRGBColorSpace as Any])
        let scale = min(CGFloat(outputWidth) / CGFloat(texture.width), CGFloat(outputHeight) / CGFloat(texture.height))
        let scaled = image?.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (CGFloat(outputWidth) - CGFloat(texture.width) * scale) / 2.0
        let y = (CGFloat(outputHeight) - CGFloat(texture.height) * scale) / 2.0
        let fitted = scaled?.transformed(by: CGAffineTransform(translationX: x, y: y))
        if let fitted {
            PipelineInstrumentation.begin("CITextureRender")
            ciContext.render(fitted,
                             to: pixelBuffer,
                             bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
                             colorSpace: sRGBColorSpace)
            PipelineInstrumentation.end("CITextureRender")
        }
        guard let sampleBuffer = try? SampleBufferFactory.makeSampleBuffer(from: pixelBuffer) else { return }
        CMSimpleQueueEnqueue(streamQueue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
        PipelineInstrumentation.event("UniCamExEnqueue")
        sendCount += 1
        if sendCount % 300 == 0 {
            let average = latencySamples == 0 ? 0 : latencyTotalMs / Double(latencySamples)
            os_log("Pipeline stats: enqueued=%{public}d dropped=%{public}d avg_texture_to_enqueue_ms=%{public}.2f", sendCount, droppedCount, average)
        }
    }

    func recordTextureLatency(milliseconds: Double) {
        stateLock.lock()
        latencyTotalMs += milliseconds
        latencySamples += 1
        stateLock.unlock()
    }

    func send(sampleBuffer: CMSampleBuffer) throws {
        guard let streamQueue else { throw BridgeError.uniCamExUnavailable }
        stateLock.lock()
        guard shouldEnqueue else {
            stateLock.unlock()
            return
        }
        shouldEnqueue = false
        stateLock.unlock()
        CMSimpleQueueEnqueue(streamQueue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
        PipelineInstrumentation.event("UniCamExEnqueue")
        sendCount += 1
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if presentationTime.timescale == 1_000_000_000, presentationTime.value > 0 {
            let now = DispatchTime.now().uptimeNanoseconds
            let sentAt = UInt64(presentationTime.value)
            if now >= sentAt {
                let latency = Double(now - sentAt) / 1_000_000
                networkLatencyTotalMs += latency
                networkLatencySamples += 1
                if networkLatencySamples == 1 {
                    os_log("Network loopback sender-to-UniCamEx-enqueue latency_ms=%{public}.2f", latency)
                }
            }
        }
        if sendCount == 1 {
            os_log("UniCamExSender: enqueued first sample buffer")
        }
        if sendCount % 150 == 0, networkLatencySamples > 0 {
            os_log("Network loopback enqueue latency avg_ms=%{public}.2f samples=%{public}d",
                   networkLatencyTotalMs / Double(networkLatencySamples), networkLatencySamples)
        }
    }

    deinit {
        if deviceID != 0, streamID != 0 {
            CMIODeviceStopStream(deviceID, streamID)
        }
    }

    private func connect() {
        guard let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown], mediaType: .video, position: .unspecified
        ).devices.first(where: { $0.localizedName == "UniCamEx" }) else {
            print("UniCamExSender: UniCamEx camera not found")
            return
        }

        var devices = CoreMediaIOUtil.deviceIDs()
        guard let foundDeviceID = devices.first(where: {
            CoreMediaIOUtil.deviceUID($0) == device.uniqueID
        }) else {
            print("UniCamExSender: CoreMediaIO device not found")
            return
        }
        devices.removeAll(keepingCapacity: false)

        let streams = CoreMediaIOUtil.streamIDs(foundDeviceID)
        guard streams.count > 1 else {
            print("UniCamExSender: expected source and sink streams, got \(streams.count)")
            return
        }
        let foundStreamID = streams[1]
        var queue: Unmanaged<CMSimpleQueue>?
        let altered: CMIODeviceStreamQueueAlteredProc = { _, _, refCon in
            guard let refCon else { return }
            let sender = Unmanaged<UniCamExSender>.fromOpaque(refCon).takeUnretainedValue()
            sender.stateLock.lock()
            sender.shouldEnqueue = true
            sender.stateLock.unlock()
        }
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        guard CMIOStreamCopyBufferQueue(foundStreamID, altered, refCon, &queue) == noErr,
              CMIODeviceStartStream(foundDeviceID, foundStreamID) == noErr else {
            print("UniCamExSender: failed to open/start UniCamEx sink stream")
            return
        }
        deviceID = foundDeviceID
        streamID = foundStreamID
        streamQueue = queue?.takeUnretainedValue()
        shouldEnqueue = true
        print("UniCamExSender: connected to UniCamEx stream")
    }
}

private enum CoreMediaIOUtil {
    static func deviceIDs() -> [CMIODeviceID] {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                 mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                 mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var result = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &result) == noErr else { return [] }
        return result
    }

    static func deviceUID(_ deviceID: CMIODeviceID) -> String? {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
                                                 mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                 mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return nil }
        var value: NSString = ""
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(deviceID, &address, 0, nil, size, &used, &value) == noErr else { return nil }
        return value as String
    }

    static func streamIDs(_ deviceID: CMIODeviceID) -> [CMIOStreamID] {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                                                 mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                 mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return [] }
        var result = [CMIOStreamID](repeating: 0, count: Int(size) / MemoryLayout<CMIOStreamID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(deviceID, &address, 0, nil, size, &used, &result) == noErr else { return [] }
        return result
    }
}
