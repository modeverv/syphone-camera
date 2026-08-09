import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import os

struct EncodedVideoFrame {
    let data: Data
    let parameterSets: Data
    let timestamp: CMTime
    let isKeyFrame: Bool
}

final class H264HardwareEncoder {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let callback: (EncodedVideoFrame) -> Void

    init(width: Int, height: Int, fps: Int, callback: @escaping (EncodedVideoFrame) -> Void) throws {
        self.width = Int32(width); self.height = Int32(height); self.callback = callback
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                 width: self.width, height: self.height,
                                                 codecType: kCMVideoCodecType_H264,
                                                 encoderSpecification: nil,
                                                 imageBufferAttributes: nil,
                                                 compressedDataAllocator: nil,
                                                 outputCallback: Self.outputCallback,
                                                 refcon: Unmanaged.passUnretained(self).toOpaque(),
                                                 compressionSessionOut: &created)
        guard status == noErr, let created else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        session = created
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: width * height * max(1, fps) / 4))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: max(1, fps * 2)))
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    deinit { if let session { VTCompressionSessionInvalidate(session) } }

    func encode(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) throws {
        guard let session else { throw BridgeError.unsupportedPath }
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
                                                      presentationTimeStamp: timestamp,
                                                      duration: CMTime(value: 1, timescale: 30),
                                                      frameProperties: nil, sourceFrameRefcon: nil,
                                                      infoFlagsOut: &flags)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard status == noErr, let refcon, let sampleBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]] else { return }
        let keyFrame = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0; var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let data = Data(bytes: pointer, count: length)
        var parameterSets = Data()
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for index in 0..<2 {
                var parameter: UnsafePointer<UInt8>?; var parameterLength = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                       parameterSetPointerOut: &parameter,
                                                                       parameterSetSizeOut: &parameterLength,
                                                                       parameterSetCountOut: nil,
                                                                       nalUnitHeaderLengthOut: nil) == noErr,
                   let parameter {
                    var length = UInt32(parameterLength).bigEndian
                    parameterSets.append(Data(bytes: &length, count: 4))
                    parameterSets.append(Data(bytes: parameter, count: parameterLength))
                }
            }
        }
        let encoder = Unmanaged<H264HardwareEncoder>.fromOpaque(refcon).takeUnretainedValue()
        os_log("VideoToolbox H.264 output: bytes=%{public}d keyframe=%{public}@", data.count, keyFrame ? "yes" : "no")
        encoder.callback(EncodedVideoFrame(data: data, parameterSets: parameterSets,
                                           timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), isKeyFrame: keyFrame))
    }
}

final class H264HardwareDecoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let width: Int
    private let height: Int
    private let callback: (CVPixelBuffer, CMTime) -> Void

    init(width: Int, height: Int, callback: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.width = width; self.height = height; self.callback = callback
    }

    func decode(accessUnit: Data, parameterSets: Data, timestamp: CMTime) throws {
        if formatDescription == nil {
            guard parameterSets.count >= 8 else {
                os_log("VideoToolbox decoder waiting for H.264 SPS/PPS")
                return
            }
            var offsets = [0, 0]; var lengths = [0, 0]; var cursor = 0
            for index in 0..<2 {
                guard cursor + 4 <= parameterSets.count else { throw BridgeError.noFrameAvailable }
                let length = Int(parameterSets[cursor]) << 24 | Int(parameterSets[cursor + 1]) << 16 | Int(parameterSets[cursor + 2]) << 8 | Int(parameterSets[cursor + 3])
                cursor += 4
                guard length > 0, length <= parameterSets.count - cursor else { throw BridgeError.noFrameAvailable }
                offsets[index] = cursor; lengths[index] = length; cursor += length
            }
            let result = parameterSets.withUnsafeBytes { bytes -> OSStatus in
                let base = bytes.bindMemory(to: UInt8.self).baseAddress!
                let pointers = [base.advanced(by: offsets[0]), base.advanced(by: offsets[1])]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                                                                            parameterSetCount: 2,
                                                                            parameterSetPointers: pointers,
                                                                            parameterSetSizes: lengths,
                                                                            nalUnitHeaderLength: 4,
                                                                            formatDescriptionOut: &formatDescription)
            }
            guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        }
        guard let formatDescription else { return }
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                              blockLength: accessUnit.count, blockAllocator: nil,
                                                              customBlockSource: nil, offsetToData: 0,
                                                              dataLength: accessUnit.count, flags: 0, blockBufferOut: &block)
        guard blockStatus == kCMBlockBufferNoErr, let block else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(blockStatus)) }
        let copyStatus = accessUnit.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: accessUnit.count) }
        guard copyStatus == kCMBlockBufferNoErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(copyStatus)) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var videoSample: CMSampleBuffer?
        let videoStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                    formatDescription: formatDescription, sampleCount: 1,
                                                    sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                    sampleSizeEntryCount: 1, sampleSizeArray: [accessUnit.count],
                                                    sampleBufferOut: &videoSample)
        guard videoStatus == noErr, let videoSample else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(videoStatus)) }
        var flags = VTDecodeInfoFlags()
        let decoder = try session ?? makeSession(formatDescription)
        let decodeStatus = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: videoSample,
                                                             flags: [], frameRefcon: nil, infoFlagsOut: &flags)
        guard decodeStatus == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(decodeStatus)) }
    }

    private func makeSession(_ format: CMVideoFormatDescription) throws -> VTDecompressionSession {
        var created: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: Self.outputCallback,
                                                            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
                                                  outputCallback: &callback, decompressionSessionOut: &created)
        guard status == noErr, let created else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        session = created
        return created
    }

    private static let outputCallback: VTDecompressionOutputCallback = { refcon, _, status, _, imageBuffer, presentationTimeStamp, _ in
        guard status == noErr, let refcon, let imageBuffer else { return }
        Unmanaged<H264HardwareDecoder>.fromOpaque(refcon).takeUnretainedValue().callback(imageBuffer, presentationTimeStamp)
    }
}
