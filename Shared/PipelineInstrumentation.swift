import Foundation
import Darwin
import os.log

enum PipelineInstrumentation {
    static let log = OSLog(subsystem: "local.syphon-unicamex.bridge", category: "pipeline")

    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }

    static func begin(_ name: StaticString) {
        os_signpost(.begin, log: log, name: name)
    }

    static func end(_ name: StaticString) {
        os_signpost(.end, log: log, name: name)
    }

    static func elapsedMilliseconds(since start: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_absolute_time() - start) * Double(info.numer) / Double(info.denom) / 1_000_000.0
    }
}
