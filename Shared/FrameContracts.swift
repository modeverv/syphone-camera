import Foundation
import CoreVideo
import CoreMedia
import Metal
import Network

protocol FrameSource: AnyObject {
    var isActive: Bool { get }
    func start() throws
    func stop()
    func latestTexture() -> MTLTexture?
    var latestTexturePublishedAt: UInt64? { get }
    func latestSampleBuffer() -> CMSampleBuffer?
}

enum NetworkTransport: String {
    case tcp
    case udp
}

/// MTU-safe datagram envelope for one fragmented encoded frame. A missing
/// fragment deliberately drops the whole frame instead of delaying newer video.
struct UDPFragmentHeader {
    static let magic: UInt32 = 0x53435531 // "SCU1"
    static let byteCount = 16

    let frameID: UInt32
    let fragmentIndex: UInt16
    let fragmentCount: UInt16
    let payloadSize: UInt16

    init(frameID: UInt32, fragmentIndex: UInt16, fragmentCount: UInt16, payloadSize: UInt16) {
        self.frameID = frameID
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.payloadSize = payloadSize
    }

    func encoded() -> Data {
        var magic = Self.magic
        var frameID = frameID
        var index = fragmentIndex
        var count = fragmentCount
        var size = payloadSize
        var reserved: UInt16 = 0
        return Data(bytes: &magic, count: 4) + Data(bytes: &frameID, count: 4)
            + Data(bytes: &index, count: 2) + Data(bytes: &count, count: 2)
            + Data(bytes: &size, count: 2) + Data(bytes: &reserved, count: 2)
    }

    init?(data: Data) {
        guard data.count >= Self.byteCount else { return nil }
        func value<T>(at offset: Int, _: T.Type) -> T { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) } }
        guard value(at: 0, UInt32.self) == Self.magic else { return nil }
        frameID = value(at: 4, UInt32.self)
        fragmentIndex = value(at: 8, UInt16.self)
        fragmentCount = value(at: 10, UInt16.self)
        payloadSize = value(at: 12, UInt16.self)
    }
}

protocol UniCamExSending: AnyObject {
    func send(texture: MTLTexture) throws
    func recordTextureLatency(milliseconds: Double)
    func send(sampleBuffer: CMSampleBuffer) throws
}

struct NetworkFrameHeader {
    static let magic: UInt32 = 0x53434231 // SCB1
    static let byteCount = 36

    let sequence: UInt64
    let timestampNanoseconds: UInt64
    let width: UInt32
    let height: UInt32
    let payloadSize: UInt32

    init(sequence: UInt64, timestampNanoseconds: UInt64, width: UInt32, height: UInt32, payloadSize: UInt32) {
        self.sequence = sequence
        self.timestampNanoseconds = timestampNanoseconds
        self.width = width
        self.height = height
        self.payloadSize = payloadSize
    }

    func encoded() -> Data {
        var values = [Self.magic, 1, width, height, payloadSize]
        var data = Data()
        values.withUnsafeBytes { data.append(contentsOf: $0) }
        var tail = [sequence, timestampNanoseconds]
        tail.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    init?(data: Data) {
        guard data.count >= Self.byteCount else { return nil }
        let words = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        guard words[0] == Self.magic, words[1] == 1 else { return nil }
        let tail = data.dropFirst(20).withUnsafeBytes { Array($0.bindMemory(to: UInt64.self)) }
        sequence = tail[0]
        timestampNanoseconds = tail[1]
        width = words[2]
        height = words[3]
        payloadSize = words[4]
    }
}

enum BridgeError: Error {
    case uniCamExUnavailable
    case noFrameAvailable
    case unsupportedPath
}
