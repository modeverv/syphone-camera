import Foundation
import CoreVideo
import CoreMedia
import Metal

protocol FrameSource: AnyObject {
    var isActive: Bool { get }
    func start() throws
    func stop()
    func latestTexture() -> MTLTexture?
    var latestTexturePublishedAt: UInt64? { get }
    func latestSampleBuffer() -> CMSampleBuffer?
}

protocol UniCamExSending: AnyObject {
    func send(texture: MTLTexture) throws
    func recordTextureLatency(milliseconds: Double)
    func send(sampleBuffer: CMSampleBuffer) throws
}

enum BridgeError: Error {
    case uniCamExUnavailable
    case noFrameAvailable
    case unsupportedPath
}
