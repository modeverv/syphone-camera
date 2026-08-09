import Foundation
import CoreMedia
import Metal

final class LatestFrameStore {
    private let lock = NSLock()
    private var texture: MTLTexture?
    private var sampleBuffer: CMSampleBuffer?
    private var texturePublishedAt: UInt64 = 0

    func publish(texture: MTLTexture) {
        lock.lock(); defer { lock.unlock() }
        self.texture = texture
        self.sampleBuffer = nil
        self.texturePublishedAt = mach_absolute_time()
    }

    func publish(sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        self.sampleBuffer = sampleBuffer
        self.texture = nil
    }

    func currentTexture() -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return texture
    }

    func currentTexturePublishedAt() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return texture == nil ? nil : texturePublishedAt
    }

    func currentSampleBuffer() -> CMSampleBuffer? {
        lock.lock(); defer { lock.unlock() }
        return sampleBuffer
    }
}
