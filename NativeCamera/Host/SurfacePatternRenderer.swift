import CoreVideo
import IOSurface
import Metal
import Foundation

/// Diagnostic source normally renders the original image into its final surface.
/// The explicit A/B comparison mode adds one GPU copy of the same image. The pool's
/// cross-process IOSurface lifetime tracking prevents reuse while consumers hold
/// a Mach-port-derived CVPixelBuffer. Allocation is bounded, including under load.
final class SurfacePatternRenderer {
    enum TransportMode: String {
        case zeroCopy = "zero-copy"
        case gpuCopy = "gpu-copy"
    }

    static let poolLimit = 8
    let mode: TransportMode
    let width: Int
    let height: Int
    private let pool: CVPixelBufferPool
    private let textureCache: CVMetalTextureCache
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let scratchPixelBuffer: CVPixelBuffer?
    private let scratchCVTexture: CVMetalTexture?
    private let scratchTexture: MTLTexture?
    private let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: poolLimit] as CFDictionary
    private(set) var seenSurfaceIDs = Set<UInt32>()
    private(set) var poolPressureDrops: UInt64 = 0
    private var renderedFrames: UInt64 = 0
    private var transportPixelCopies: UInt64 = 0
    private var gpuTimedFrames: UInt64 = 0
    private var gpuTimingUnavailableFrames: UInt64 = 0
    private var gpuCommandSecondsTotal: Double = 0
    private var gpuCommandSecondsMax: Double = 0
    private var renderWallSecondsTotal: Double = 0
    private var renderWallSecondsMax: Double = 0

    /// Cumulative counters permit warm-up subtraction without per-frame logging.
    /// GPU duration is the completed command buffer's execution interval, including
    /// the pattern kernel and optional blit. It is not system GPU utilization and
    /// does not isolate the blit encoder's duration from the pattern kernel.
    var performanceSnapshot: [String: Any] {
        ["transportMode": mode.rawValue, "renderedFrames": renderedFrames,
         "outputWidth": width, "outputHeight": height,
         "transportPixelCopies": transportPixelCopies,
         "scratchBufferCount": scratchPixelBuffer == nil ? 0 : 1,
         "scratchBufferBytes": scratchPixelBuffer.map { CVPixelBufferGetDataSize($0) } ?? 0,
         "scratchBytesPerRow": scratchPixelBuffer.map { CVPixelBufferGetBytesPerRow($0) } ?? 0,
         "gpuTimedFrames": gpuTimedFrames, "gpuTimingUnavailableFrames": gpuTimingUnavailableFrames,
         "gpuCommandSecondsTotal": gpuCommandSecondsTotal, "gpuCommandSecondsMax": gpuCommandSecondsMax,
         "renderWallSecondsTotal": renderWallSecondsTotal, "renderWallSecondsMax": renderWallSecondsMax]
    }

    init(mode: TransportMode = .zeroCopy, width: Int = 1920, height: Int = 1080) throws {
        guard (width == 1920 && height == 1080) || (width == 1280 && height == 720) else {
            throw NativeCameraError.message("Expected 1920x1080 or 1280x720 output")
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NativeCameraError.message("Metal device unavailable")
        }
        self.mode = mode
        self.width = width
        self.height = height
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "pattern")!)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw NativeCameraError.message("Texture cache creation failed")
        }
        textureCache = cache
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        if mode == .gpuCopy {
            // Use the same storage/layout as the destination. A private Metal
            // scratch texture would also change the pattern kernel's target
            // storage and confound a comparison intended to add only one copy.
            var scratch: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                      attrs as CFDictionary, &scratch) == kCVReturnSuccess,
                  let scratch else {
                throw NativeCameraError.message("Comparison scratch buffer creation failed")
            }
            var wrapped: CVMetalTexture?
            let textureAttrs = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderWrite.rawValue] as CFDictionary
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, scratch, textureAttrs,
                .bgra8Unorm, width, height, 0, &wrapped) == kCVReturnSuccess,
                  let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else {
                throw NativeCameraError.message("Comparison scratch texture binding failed")
            }
            texture.label = "A/B IOSurface source before one GPU copy"
            scratchPixelBuffer = scratch
            scratchCVTexture = wrapped
            scratchTexture = texture
        } else {
            scratchPixelBuffer = nil; scratchCVTexture = nil; scratchTexture = nil
        }
        var created: CVPixelBufferPool?
        let poolAttrs = [kCVPixelBufferPoolMinimumBufferCountKey as String: Self.poolLimit,
                         kCVPixelBufferPoolMaximumBufferAgeKey as String: 0] as CFDictionary
        guard CVPixelBufferPoolCreate(nil, poolAttrs, attrs as CFDictionary, &created) == kCVReturnSuccess,
              let created else { throw NativeCameraError.message("Pixel buffer pool creation failed") }
        pool = created
        var warm: [CVPixelBuffer] = []
        for _ in 0..<Self.poolLimit {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &buffer) == kCVReturnSuccess,
                  let buffer else { throw NativeCameraError.message("Pool warm-up failed") }
            warm.append(buffer)
            seenSurfaceIDs.insert(IOSurfaceGetID(CVPixelBufferGetIOSurface(buffer)!.takeUnretainedValue()))
        }
        // All eight buffers must coexist during warm-up. Subsequent allocations
        // reuse only released slots; the threshold forbids unbounded growth.
        withExtendedLifetime(warm) {}
    }

    func render(sequence: UInt64) throws -> CVPixelBuffer? {
        let wallStart = ProcessInfo.processInfo.systemUptime
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &buffer)
        if status == kCVReturnWouldExceedAllocationThreshold { poolPressureDrops += 1; return nil }
        guard status == kCVReturnSuccess, let buffer else { throw NativeCameraError.message("Pool: \(status)") }
        let surface = CVPixelBufferGetIOSurface(buffer)!.takeUnretainedValue()
        seenSurfaceIDs.insert(IOSurfaceGetID(surface))
        guard seenSurfaceIDs.count <= Self.poolLimit else { throw NativeCameraError.message("Surface pool bound violated") }
        var cvTexture: CVMetalTexture?
        let attrs = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderWrite.rawValue] as CFDictionary
        let textureStatus = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, attrs,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard textureStatus == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw NativeCameraError.message("Metal surface binding: \(textureStatus)")
        }
        var words = SIMD2<UInt32>(UInt32(truncatingIfNeeded: sequence), UInt32(truncatingIfNeeded: sequence >> 32))
        encoder.setComputePipelineState(pipeline)
        // Both paths execute exactly the same kernel, dimensions, and sequence.
        // Only the comparison path writes a second IOSurface and then copies it.
        if let scratchPixelBuffer, let scratchTexture {
            guard CVPixelBufferGetBytesPerRow(scratchPixelBuffer) == CVPixelBufferGetBytesPerRow(buffer),
                  scratchTexture.storageMode == texture.storageMode else {
                throw NativeCameraError.message("Comparison source/destination storage differs")
            }
        }
        encoder.setTexture(scratchTexture ?? texture, index: 0)
        encoder.setBytes(&words, length: MemoryLayout<SIMD2<UInt32>>.size, index: 0)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / threadWidth))
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
        encoder.endEncoding()
        if let scratchTexture {
            guard let blit = command.makeBlitCommandEncoder() else {
                throw NativeCameraError.message("Comparison blit encoder creation failed")
            }
            blit.copy(from: scratchTexture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw NativeCameraError.message("GPU source render failed: \(String(describing: command.error))") }
        renderedFrames += 1
        if mode == .gpuCopy { transportPixelCopies += 1 }
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
        withExtendedLifetime(cvTexture) {}
        return buffer
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void pattern(texture2d<float, access::write> out [[texture(0)]],
                        constant uint2 &seq [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= out.get_width() || p.y >= out.get_height()) return;
        float4 color = float4(float(p.x) / float(out.get_width()),
                              float(p.y) / float(out.get_height()), float(seq.x % 127) / 126.0, 1.0);
        // Keep motion and stripe thickness proportional to the output image.
        // At 1080p this is pixel-identical to the original benchmark pattern.
        uint row = (((seq.x * 7) % 1080) * out.get_height()) / 1080;
        uint stripeHeight = out.get_height() / 90;
        if (p.y >= row && p.y < row + stripeHeight) color = float4(1.0);
        if (p.y == 0 && p.x < 8) {
            uint value = p.x < 4 ? seq.x : seq.y;
            uint byte = (value >> ((p.x % 4) * 8)) & 255;
            color = float4(165.0/255.0, 90.0/255.0, float(byte)/255.0, 1.0);
        }
        out.write(color, p);
    }
    """
}
