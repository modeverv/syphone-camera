import AVFoundation
import CoreImage
import CoreMedia
import CoreMediaIO
import Foundation
import IOSurface
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
    private var metalBlitCount = 0
    private var ciRenderCount = 0
    private var latencyTotalMs = 0.0
    private var latencySamples = 0
    private var networkLatencyTotalMs = 0.0
    private var networkLatencySamples = 0
    private let ciContext: CIContext?
    private let metalDevice: MTLDevice?
    private let metalCommandQueue: MTLCommandQueue?
    private let metalTextureCache: CVMetalTextureCache?
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private var pixelBufferPool: CVPixelBufferPool?
    private var didLogTextureCompatibility = false
    private var didProbeDirectIOSurface = false
    private var didReportPath = false

    private let outputWidth = 1920
    private let outputHeight = 1080

    init() {
        let device = MTLCreateSystemDefaultDevice()
        metalDevice = device
        metalCommandQueue = device?.makeCommandQueue()
        var textureCache: CVMetalTextureCache?
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
        metalTextureCache = textureCache
        ciContext = device.map { CIContext(mtlDevice: $0) }
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
        logCompatibilityIfNeeded(texture: texture, pooledBuffer: pixelBuffer)
        if texture.width == outputWidth,
           texture.height == outputHeight,
           texture.pixelFormat == .bgra8Unorm,
           blit(texture: texture, into: pixelBuffer) {
            metalBlitCount += 1
            reportPathOnce("METAL_BLIT")
            enqueue(pixelBuffer: pixelBuffer, streamQueue: streamQueue)
            return
        }
        let image = CIImage(mtlTexture: texture, options: [.colorSpace: sRGBColorSpace as Any])
        let isExactSize = texture.width == outputWidth && texture.height == outputHeight
        let fitted: CIImage?
        if isExactSize {
            fitted = image
        } else {
            let scale = min(CGFloat(outputWidth) / CGFloat(texture.width), CGFloat(outputHeight) / CGFloat(texture.height))
            let scaled = image?.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let x = (CGFloat(outputWidth) - CGFloat(texture.width) * scale) / 2.0
            let y = (CGFloat(outputHeight) - CGFloat(texture.height) * scale) / 2.0
            fitted = scaled?.transformed(by: CGAffineTransform(translationX: x, y: y))
        }
        if let fitted {
            ciRenderCount += 1
            PipelineInstrumentation.begin("CITextureRender")
            ciContext.render(fitted,
                             to: pixelBuffer,
                             bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
                             colorSpace: sRGBColorSpace)
            PipelineInstrumentation.end("CITextureRender")
        }
        reportPathOnce("CORE_IMAGE_FALLBACK")
        guard let sampleBuffer = try? SampleBufferFactory.makeSampleBuffer(from: pixelBuffer) else { return }
        enqueue(sampleBuffer: sampleBuffer, streamQueue: streamQueue)
    }

    private func enqueue(pixelBuffer: CVPixelBuffer, streamQueue: CMSimpleQueue) {
        guard let sampleBuffer = try? SampleBufferFactory.makeSampleBuffer(from: pixelBuffer) else { return }
        enqueue(sampleBuffer: sampleBuffer, streamQueue: streamQueue)
    }

    private func enqueue(sampleBuffer: CMSampleBuffer, streamQueue: CMSimpleQueue) {
        CMSimpleQueueEnqueue(streamQueue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
        PipelineInstrumentation.event("UniCamExEnqueue")
        sendCount += 1
        if sendCount % 300 == 0 {
            let average = latencySamples == 0 ? 0 : latencyTotalMs / Double(latencySamples)
            os_log("Pipeline stats: enqueued=%{public}d dropped=%{public}d metal_blit=%{public}d ci_render=%{public}d avg_texture_to_enqueue_ms=%{public}.2f", sendCount, droppedCount, metalBlitCount, ciRenderCount, average)
        }
    }

    private func blit(texture: MTLTexture, into pixelBuffer: CVPixelBuffer) -> Bool {
        guard let metalDevice, let metalCommandQueue, let metalTextureCache else { return false }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            metalTextureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            outputWidth,
            outputHeight,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let destination = CVMetalTextureGetTexture(cvTexture),
              destination.device === metalDevice,
              let commandBuffer = metalCommandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder() else { return false }
        PipelineInstrumentation.begin("MetalBlit")
        encoder.copy(from: texture,
                     sourceSlice: 0,
                     sourceLevel: 0,
                     sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1),
                     to: destination,
                     destinationSlice: 0,
                     destinationLevel: 0,
                     destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        PipelineInstrumentation.end("MetalBlit")
        return commandBuffer.status == .completed
    }

    private func reportPathOnce(_ path: String) {
        guard !didReportPath else { return }
        didReportPath = true
        report("Video path: \(path)")
    }

    private func logCompatibilityIfNeeded(texture: MTLTexture, pooledBuffer: CVPixelBuffer) {
        guard !didLogTextureCompatibility else { return }
        didLogTextureCompatibility = true
        let sourceSurface = texture.iosurface
        let destinationSurface = CVPixelBufferGetIOSurface(pooledBuffer)?.takeUnretainedValue()
        report("Surface compatibility report")
        report("Property                  Syphon                 UniCamEx pool")
        report("width                     \(texture.width)                 \(CVPixelBufferGetWidth(pooledBuffer))")
        report("height                    \(texture.height)                \(CVPixelBufferGetHeight(pooledBuffer))")
        report("pixel format              \(String(describing: texture.pixelFormat))       32BGRA")
        report("storage / usage           \(String(describing: texture.storageMode)) / \(texture.usage.rawValue)       n/a")
        report("pool bytesPerRow/planar   n/a                    \(CVPixelBufferGetBytesPerRow(pooledBuffer)) / \(CVPixelBufferIsPlanar(pooledBuffer))")
        report("pool planeCount           n/a                    \(CVPixelBufferGetPlaneCount(pooledBuffer))")
        let sourceSurfaceState = sourceSurface == nil ? "nil" : "present"
        let destinationSurfaceState = destinationSurface == nil ? "nil" : "present"
        report("texture IOSurface         \(sourceSurfaceState)                 \(destinationSurfaceState)")
        logSurface("Syphon", sourceSurface)
        logSurface("UniCamEx", destinationSurface)
        probeDirectIOSurface(sourceSurface: sourceSurface, destination: pooledBuffer)
    }

    private func logSurface(_ label: String, _ surface: IOSurface?) {
        guard let surface else {
            report("\(label) IOSurface: unavailable")
            return
        }
        report("\(label) IOSurface width=\(IOSurfaceGetWidth(surface)) height=\(IOSurfaceGetHeight(surface)) bytesPerRow=\(IOSurfaceGetBytesPerRow(surface)) bytesPerElement=\(IOSurfaceGetBytesPerElement(surface)) allocSize=\(IOSurfaceGetAllocSize(surface)) pixelFormat=\(String(describing: IOSurfaceGetPixelFormat(surface))) planeCount=\(IOSurfaceGetPlaneCount(surface)) seed=\(IOSurfaceGetSeed(surface))")
    }

    private func probeDirectIOSurface(sourceSurface: IOSurface?, destination: CVPixelBuffer) {
        guard !didProbeDirectIOSurface else { return }
        didProbeDirectIOSurface = true
        guard let sourceSurface else {
            report("Direct IOSurface probe stage 1 retrieve: unavailable (texture.iosurface == nil)")
            report("Direct IOSurface probe stages 5-7 enqueue/consume/visible-frame: not attempted")
            return
        }
        var wrapped: Unmanaged<CVPixelBuffer>?
        PipelineInstrumentation.begin("DirectIOSurfaceWrap")
        let wrapStatus = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, sourceSurface, nil, &wrapped)
        PipelineInstrumentation.end("DirectIOSurfaceWrap")
        report("Direct IOSurface probe stage 2 wrap: \(wrapStatus) (\(cvStatusName(wrapStatus)))")
        guard wrapStatus == kCVReturnSuccess, let wrapped = wrapped?.takeUnretainedValue() else {
            report("Direct IOSurface probe stages 3-7: not attempted after wrap failure")
            return
        }
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: wrapped, formatDescriptionOut: &format)
        report("Direct IOSurface probe stage 3 format description: \(formatStatus)")
        guard formatStatus == noErr, let format else {
            report("Direct IOSurface probe stages 4-7: not attempted after format-description failure")
            return
        }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime.invalid, presentationTimeStamp: CMTime.zero, decodeTimeStamp: CMTime.invalid)
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: wrapped, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        report("Direct IOSurface probe stage 4 sample buffer: \(sampleStatus)")
        if sampleStatus == noErr {
            report("Direct IOSurface probe: wrapper/sample creation succeeded; enqueue/consumer validation remains intentionally disabled")
        }
        report("Direct IOSurface probe stage 5 enqueue: not attempted (would alter production sink state)")
        report("Direct IOSurface probe stage 6 UniCamEx consume: not attempted")
        report("Direct IOSurface probe stage 7 visible frame: not attempted")
        _ = destination
    }

    private func cvStatusName(_ status: CVReturn) -> String {
        switch status {
        case kCVReturnSuccess: return "success"
        case kCVReturnInvalidArgument: return "invalid-argument"
        case kCVReturnAllocationFailed: return "allocation-failed"
        case kCVReturnUnsupported: return "unsupported"
        default: return "unknown"
        }
    }

    private func report(_ message: String) {
        print(message)
        os_log("%{public}@", message)
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
