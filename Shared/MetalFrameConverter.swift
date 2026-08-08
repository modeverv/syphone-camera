import Foundation
import Metal
import CoreVideo

/// GPU-only frame conversion path for the common case where the incoming Syphon
/// texture is already BGRA8 and matches the requested output dimensions.
///
/// The MVP does a Metal blit into a Metal-compatible CVPixelBuffer.
/// If WMC produces a different size, `allowScaling == false` drops the frame.
/// A later optimization may add MPS/Metal scaling.
final class MetalFrameConverter {
    enum ConverterError: Error {
        case noCommandQueue
        case pixelBufferPoolCreation(OSStatus)
        case textureCacheCreation(CVReturn)
        case pixelBufferCreation(CVReturn)
        case textureCreation
        case incompatibleTexture
        case commandBufferCreation
        case blitEncoderCreation
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pool: CVPixelBufferPool!
    private var textureCache: CVMetalTextureCache!

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw ConverterError.noCommandQueue
        }
        self.commandQueue = queue

        var pool: CVPixelBufferPool?
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3
        ]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: Int(CameraConstants.width),
            kCVPixelBufferHeightKey: Int(CameraConstants.height),
            kCVPixelBufferPixelFormatTypeKey: CameraConstants.pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )
        guard poolStatus == kCVReturnSuccess, let pool else {
            throw ConverterError.pixelBufferPoolCreation(poolStatus)
        }
        self.pool = pool

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw ConverterError.textureCacheCreation(cacheStatus)
        }
        self.textureCache = cache
    }

    func convert(_ source: MTLTexture) throws -> CVPixelBuffer {
        guard source.width == Int(CameraConstants.width),
              source.height == Int(CameraConstants.height),
              source.pixelFormat == .bgra8Unorm ||
              source.pixelFormat == .bgra8Unorm_srgb else {
            throw ConverterError.incompatibleTexture
        }

        var pixelBuffer: CVPixelBuffer?
        let pbStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer
        )
        guard pbStatus == kCVReturnSuccess, let pixelBuffer else {
            throw ConverterError.pixelBufferCreation(pbStatus)
        }

        var cvTexture: CVMetalTexture?
        let textureStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            Int(CameraConstants.width),
            Int(CameraConstants.height),
            0,
            &cvTexture
        )
        guard textureStatus == kCVReturnSuccess,
              let cvTexture,
              let destination = CVMetalTextureGetTexture(cvTexture) else {
            throw ConverterError.textureCreation
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw ConverterError.commandBufferCreation
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw ConverterError.blitEncoderCreation
        }

        let size = MTLSize(
            width: Int(CameraConstants.width),
            height: Int(CameraConstants.height),
            depth: 1
        )
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: size,
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return pixelBuffer
    }
}
