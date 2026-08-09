import Foundation
import CoreMedia
import CoreVideo

final class SampleBufferFactory {
    static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer,
                                 formatDescription: CMVideoFormatDescription? = nil,
                                 hostTime: UInt64 = mach_absolute_time(),
                                 presentationTime: CMTime? = nil) throws -> CMSampleBuffer {
        let fmt: CMVideoFormatDescription
        if let formatDescription {
            fmt = formatDescription
        } else {
            var created: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                      imageBuffer: pixelBuffer,
                                                                      formatDescriptionOut: &created)
            guard status == noErr, let created else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            fmt = created
        }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let hostNanoseconds = UInt64(hostTime) * UInt64(timebase.numer) / UInt64(timebase.denom)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: presentationTime ?? CMTime(value: Int64(hostNanoseconds), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                               imageBuffer: pixelBuffer,
                                                               formatDescription: fmt,
                                                               sampleTiming: &timing,
                                                               sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return sampleBuffer
    }
}
