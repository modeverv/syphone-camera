import CoreMediaIO
import CoreMedia
import CoreVideo
import IOSurface
import Foundation

enum NativeCameraError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// All methods are called on the producer's serial queue. Only immutable,
/// IOSurface-backed frames whose owner participates in CoreVideo/Mach-port
/// lifetime tracking may be submitted. Retaining a mutable Syphon texture is
/// explicitly insufficient for this API's ownership contract.
final class NativeCameraSink {
    static let cameraName = "Syphon Zero Copy Camera"
    private var device: CMIODeviceID = 0
    private var stream: CMIOStreamID = 0
    private var bufferQueue: CMSimpleQueue?
    private var format: CMVideoFormatDescription?
    private var width = 1920
    private var height = 1080

    func connect(width: Int = 1920, height: Int = 1080) throws {
        let stopStatus = close()
        guard stopStatus == noErr else { throw NativeCameraError.message("CMIO stop before reconnect: \(stopStatus)") }
        guard let found = CMIORead.ids(CMIOObjectID(kCMIOObjectSystemObject), UInt32(kCMIOHardwarePropertyDevices))
            .first(where: { CMIORead.string($0, UInt32(kCMIOObjectPropertyName)) == Self.cameraName }) else {
            throw NativeCameraError.message("カメラが見つかりません。拡張を有効化してください。")
        }
        let streams = CMIORead.ids(found, UInt32(kCMIODevicePropertyStreams))
        guard let output = streams.first(where: { CMIORead.integer($0, UInt32(kCMIOStreamPropertyDirection)) == 0 }) else {
            throw NativeCameraError.message("カメラの入力用 sink stream が見つかりません。")
        }
        // Select an advertised native format before starting the producer.
        // The extension refuses resolution changes while either stream is active.
        var formatsAddress = CMIORead.address(UInt32(kCMIOStreamPropertyFormatDescriptions))
        var formatsValue: Unmanaged<CFArray>?
        var used: UInt32 = 0
        let formatsStatus = CMIOObjectGetPropertyData(output, &formatsAddress, 0, nil,
            UInt32(MemoryLayout<Unmanaged<CFArray>?>.size), &used, &formatsValue)
        guard formatsStatus == noErr, let formatsValue else {
            throw NativeCameraError.message("CMIO formats: \(formatsStatus)")
        }
        let formats = formatsValue.takeRetainedValue() as! [CMFormatDescription]
        guard var selected = formats.first(where: {
            let size = CMVideoFormatDescriptionGetDimensions($0)
            return size.width == width && size.height == height &&
                CMFormatDescriptionGetMediaSubType($0) == kCVPixelFormatType_32BGRA
        }) else { throw NativeCameraError.message("カメラ拡張が \(width)×\(height) BGRA に対応していません。更新してください。") }
        var formatAddress = CMIORead.address(UInt32(kCMIOStreamPropertyFormatDescription))
        let formatStatus = CMIOObjectSetPropertyData(output, &formatAddress, 0, nil,
            UInt32(MemoryLayout<CMFormatDescription>.size), &selected)
        guard formatStatus == noErr else {
            throw NativeCameraError.message("解像度を変更できません (\(formatStatus))。受信アプリのカメラを停止してから切り替えてください。")
        }
        var copied: Unmanaged<CMSimpleQueue>?
        // A nil callback is an unregister operation; current CMIO can return
        // success with a nil queue in that case. No refCon is needed because
        // availability is polled on the producer queue.
        let altered: CMIODeviceStreamQueueAlteredProc = { _, _, _ in }
        let queueStatus = CMIOStreamCopyBufferQueue(output, altered, nil, &copied)
        guard queueStatus == noErr, let copied else {
            throw NativeCameraError.message("CMIO queue: \(queueStatus)")
        }
        let queue = copied.takeRetainedValue()
        let startStatus = CMIODeviceStartStream(found, output)
        guard startStatus == noErr else { throw NativeCameraError.message("CMIO start: \(startStatus)") }
        device = found; stream = output; bufferQueue = queue
        self.width = width; self.height = height
    }

    var hasCapacity: Bool {
        guard let bufferQueue else { return false }
        return CMSimpleQueueGetCount(bufferQueue) < CMSimpleQueueGetCapacity(bufferQueue)
    }

    /// Creates metadata wrappers only. No readback, blit, conversion, or image allocation.
    @discardableResult
    func submit(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) throws -> Bool {
        guard CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetIOSurface(pixelBuffer) != nil else {
            throw NativeCameraError.message("直接転送には選択中の \(width)×\(height) BGRA IOSurface が必要です。")
        }
        guard let bufferQueue, hasCapacity else { return false }
        if format == nil {
            let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer, formatDescriptionOut: &format)
            guard status == noErr else { throw NativeCameraError.message("Format: \(status)") }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                       presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw NativeCameraError.message("Sample: \(status)") }
        let token = Unmanaged.passRetained(sample)
        let enqueueStatus = CMSimpleQueueEnqueue(bufferQueue, element: token.toOpaque())
        if enqueueStatus != noErr { token.release(); return false }
        return true
    }

    func telemetry() -> String? { device == 0 ? nil : CMIORead.string(device, 0x7a637079) }

    @discardableResult
    func close() -> OSStatus {
        let status = device != 0 && stream != 0 ? CMIODeviceStopStream(device, stream) : noErr
        // Ownership transfers to CMIO on successful enqueue. Stop the stream
        // and relinquish this reference; do not race its consumer by dequeuing.
        bufferQueue = nil; device = 0; stream = 0; format = nil
        return status
    }
    deinit { close() }
}

enum CMIORead {
    static func address(_ selector: UInt32) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
                                  mElement: UInt32(kCMIOObjectPropertyElementMain))
    }
    static func ids(_ object: CMIOObjectID, _ selector: UInt32) -> [UInt32] {
        var a = address(selector); var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
        var used: UInt32 = 0
        let status = values.withUnsafeMutableBytes {
            CMIOObjectGetPropertyData(object, &a, 0, nil, size, &used, $0.baseAddress!)
        }
        return status == noErr ? values : []
    }
    static func integer(_ object: CMIOObjectID, _ selector: UInt32) -> UInt32? {
        var a = address(selector); var value: UInt32 = 0; var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(object, &a, 0, nil, 4, &used, &value)
        return status == noErr ? value : nil
    }
    static func string(_ object: CMIOObjectID, _ selector: UInt32) -> String? {
        var a = address(selector); var value: Unmanaged<CFString>?; var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(object, &a, 0, nil,
            UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value)
        // CMIO CF-valued properties follow the GetPropertyData ownership rule:
        // caller releases returned CF objects (CMIOHardwareObject.h).
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
