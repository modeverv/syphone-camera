import Foundation
import CoreVideo
import IOSurface
import Metal
import Syphon

/// A bounded snapshot adapter for ordinary, mutable Syphon producers such as
/// the distributed Webcam Motion Receiver. Call only on an admitted 30 Hz tick,
/// after checking sink capacity. Resize and vertical flip share one GPU pass
/// into the final CVPixelBuffer; the extension can forward that buffer unchanged.
/// This is not source-to-consumer zero-copy. Syphon cannot guarantee the source
/// texture stays immutable during GPU sampling, but it never escapes this call.
final class SyphonResizingSource {
    static let poolLimit = 8
    let width: Int
    let height: Int
    let serverName: String
    private let device: MTLDevice
    private let client: SyphonMetalClient
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let pool: CVPixelBufferPool
    private let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: poolLimit] as CFDictionary
    private(set) var poolPressureDrops: UInt64 = 0
    private(set) var seenSurfaceIDs = Set<UInt32>()
    private var noNewFrameTicks: UInt64 = 0
    private var unavailableFrameTicks: UInt64 = 0
    private var renderedFrames: UInt64 = 0
    private var repeatedOutputFrames: UInt64 = 0
    // Retain only our completed final image, never the producer's mutable texture.
    // The pool cannot reuse this slot while cached or retained by any consumer.
    private var lastOwnedBuffer: CVPixelBuffer?
    private var lastSequence: UInt64 = 0
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var sourcePixelFormat: UInt = 0
    private var gpuTimedFrames: UInt64 = 0
    private var gpuTimingUnavailableFrames: UInt64 = 0
    private var gpuCommandSecondsTotal: Double = 0
    private var gpuCommandSecondsMax: Double = 0
    private var renderWallSecondsTotal: Double = 0
    private var renderWallSecondsMax: Double = 0

    var performanceSnapshot: [String: Any] {
        ["transportMode": "syphon-gpu-resize-flip", "sourceKind": "syphon",
         "samplingMode": "latest-texture-every-admitted-tick", "newFrameFlagGatesSampling": false,
         "uniqueSourceImagesMeasured": false,
         "sourceServer": serverName, "sourceWidth": sourceWidth, "sourceHeight": sourceHeight,
         "sourcePixelFormat": sourcePixelFormat, "outputWidth": width, "outputHeight": height,
         "renderedFrames": renderedFrames, "lastSequence": lastSequence,
         "freshRenderedFrames": renderedFrames, "repeatedOutputFrames": repeatedOutputFrames,
         "totalOutputFrames": renderedFrames + repeatedOutputFrames,
         "cachedOutputBufferCount": lastOwnedBuffer == nil ? 0 : 1,
         "sourceTransformPasses": renderedFrames, "transportPixelCopies": renderedFrames,
         "cpuPixelCopies": 0, "scratchBufferCount": 0, "scratchBufferBytes": 0,
         "poolPressureDrops": poolPressureDrops, "noNewFrameTicks": noNewFrameTicks,
         "unavailableFrameTicks": unavailableFrameTicks,
         "sourceImmutabilityGuaranteed": false,
         "sourceLifetime": "Latest mutable Syphon texture sampled immediately; not retained across ticks",
         "gpuTimedFrames": gpuTimedFrames, "gpuTimingUnavailableFrames": gpuTimingUnavailableFrames,
         "gpuCommandSecondsTotal": gpuCommandSecondsTotal, "gpuCommandSecondsMax": gpuCommandSecondsMax,
         "renderWallSecondsTotal": renderWallSecondsTotal, "renderWallSecondsMax": renderWallSecondsMax]
    }

    init(width: Int, height: Int, serverName requestedServerName: String? = nil) throws {
        guard (width == 1920 && height == 1080) || (width == 1280 && height == 720) else {
            throw NativeCameraError.message("Expected 1920x1080 or 1280x720 output")
        }
        let servers = SyphonServerDirectory.shared().servers
        let candidates = servers.filter { description in
            let name = description[SyphonServerDescriptionNameKey] as? String ?? ""
            let app = description[SyphonServerDescriptionAppNameKey] as? String ?? ""
            if let requestedServerName {
                return name.caseInsensitiveCompare(requestedServerName) == .orderedSame ||
                    (app + "/" + name).caseInsensitiveCompare(requestedServerName) == .orderedSame
            }
            return name.localizedCaseInsensitiveContains("Webcam Motion Receiver") ||
                app.localizedCaseInsensitiveContains("Webcam Motion Receiver") ||
                app.localizedCaseInsensitiveContains("Webcam Motion Capture")
        }
        let available = servers.map { description in
            let name = description[SyphonServerDescriptionNameKey] as? String ?? "(unnamed)"
            let app = description[SyphonServerDescriptionAppNameKey] as? String ?? "(unknown app)"
            return app + "/" + name
        }.sorted().joined(separator: ", ")
        guard candidates.count == 1, let selected = candidates.first else {
            throw NativeCameraError.message("Expected one matching Syphon server, found \(candidates.count). " +
                "Discovered: \(available.isEmpty ? "none (allow discovery time and start WMC)" : available)")
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NativeCameraError.message("Metal device unavailable")
        }
        self.width = width
        self.height = height
        self.device = device
        self.queue = queue
        let app = selected[SyphonServerDescriptionAppNameKey] as? String ?? "(unknown app)"
        let name = selected[SyphonServerDescriptionNameKey] as? String ?? "(unnamed)"
        self.serverName = app + "/" + name
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let function = library.makeFunction(name: "resizeFlip") else {
            throw NativeCameraError.message("Syphon resize shader missing")
        }
        pipeline = try device.makeComputePipelineState(function: function)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw NativeCameraError.message("Syphon texture cache creation failed")
        }
        textureCache = cache
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true]
        let poolAttrs = [kCVPixelBufferPoolMinimumBufferCountKey as String: Self.poolLimit,
                         kCVPixelBufferPoolMaximumBufferAgeKey as String: 0] as CFDictionary
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, poolAttrs, attrs as CFDictionary, &created) == kCVReturnSuccess,
              let created else { throw NativeCameraError.message("Syphon output pool creation failed") }
        pool = created
        var warm: [CVPixelBuffer] = []
        for _ in 0..<Self.poolLimit {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &buffer) == kCVReturnSuccess,
                  let buffer, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
                throw NativeCameraError.message("Syphon output pool warm-up failed")
            }
            warm.append(buffer)
            seenSurfaceIDs.insert(IOSurfaceGetID(surface))
        }
        withExtendedLifetime(warm) {}
        // No new-frame callback: frames that miss admission never trigger a GPU conversion.
        client = SyphonMetalClient(serverDescription: selected, device: device,
                                   options: nil, newFrameHandler: nil)
        guard client.isValid else { throw NativeCameraError.message("Cannot connect to \(self.serverName)") }
    }

    deinit { client.stop() }

    func render(sequence: UInt64) throws -> CVPixelBuffer? {
        guard client.isValid else { throw NativeCameraError.message("Syphon server disconnected: \(serverName)") }
        // WMC mutates a shared texture. The frame flag is advisory: sampling
        // the current image must not depend on notification/seed timing.
        if !client.hasNewFrame { noNewFrameTicks += 1 }
        let wallStart = ProcessInfo.processInfo.systemUptime
        guard let source = client.newFrameImage() else {
            unavailableFrameTicks += 1
            guard let lastOwnedBuffer else { return nil }
            // Only a temporarily unavailable texture can repeat our immutable
            // completed image. A disconnected server still throws above.
            repeatedOutputFrames += 1
            lastSequence = sequence
            return lastOwnedBuffer
        }
        var buffer: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &buffer)
        if poolStatus == kCVReturnWouldExceedAllocationThreshold { poolPressureDrops += 1; return nil }
        guard poolStatus == kCVReturnSuccess, let buffer,
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
            throw NativeCameraError.message("Syphon output pool: \(poolStatus)")
        }
        seenSurfaceIDs.insert(IOSurfaceGetID(surface))
        guard seenSurfaceIDs.count <= Self.poolLimit else {
            throw NativeCameraError.message("Syphon surface pool bound violated")
        }
        guard source.device.registryID == device.registryID,
              source.textureType == .type2D, source.sampleCount == 1,
              source.pixelFormat == .bgra8Unorm || source.pixelFormat == .rgba8Unorm else {
            throw NativeCameraError.message("Unsupported Syphon texture: \(source.width)x\(source.height), " +
                "format \(source.pixelFormat.rawValue), type \(source.textureType.rawValue)")
        }
        sourceWidth = source.width; sourceHeight = source.height
        sourcePixelFormat = source.pixelFormat.rawValue
        var wrapped: CVMetalTexture?
        let textureAttrs = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderWrite.rawValue] as CFDictionary
        let bindStatus = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, textureAttrs,
            .bgra8Unorm, width, height, 0, &wrapped)
        guard bindStatus == kCVReturnSuccess, let wrapped,
              let destination = CVMetalTextureGetTexture(wrapped),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw NativeCameraError.message("Syphon output texture binding: \(bindStatus)")
        }
        command.label = "One-pass Syphon resize and vertical flip"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / threadWidth))
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
        encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else {
            throw NativeCameraError.message("Syphon GPU resize failed: \(String(describing: command.error))")
        }
        renderedFrames += 1; lastSequence = sequence
        let gpuStart = command.gpuStartTime
        let gpuEnd = command.gpuEndTime
        let gpuSeconds = gpuEnd - gpuStart
        if gpuStart > 0, gpuEnd.isFinite, gpuSeconds.isFinite, gpuSeconds > 0 {
            gpuTimedFrames += 1
            gpuCommandSecondsTotal += gpuSeconds
            gpuCommandSecondsMax = max(gpuCommandSecondsMax, gpuSeconds)
        } else { gpuTimingUnavailableFrames += 1 }
        let wallSeconds = ProcessInfo.processInfo.systemUptime - wallStart
        renderWallSecondsTotal += wallSeconds
        renderWallSecondsMax = max(renderWallSecondsMax, wallSeconds)
        lastOwnedBuffer = buffer
        withExtendedLifetime((source, wrapped)) {}
        return buffer
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void resizeFlip(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           uint2 p [[thread_position_in_grid]]) {
        if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
        float2 inputSize(src.get_width(), src.get_height());
        float2 outputSize(dst.get_width(), dst.get_height());
        float scale = min(outputSize.x / inputSize.x, outputSize.y / inputSize.y);
        float2 fittedSize = inputSize * scale;
        float2 local = float2(p) + 0.5 - (outputSize - fittedSize) * 0.5;
        if (any(local < 0.0) || any(local >= fittedSize)) {
            dst.write(float4(0.0, 0.0, 0.0, 1.0), p);
            return;
        }
        float2 uv = local / fittedSize;
        uv.y = 1.0 - uv.y;
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        dst.write(src.sample(linearSampler, uv), p);
    }
    """
}
