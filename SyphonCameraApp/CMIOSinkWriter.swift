import Foundation
import AVFoundation
import CoreMedia
import CoreMediaIO

/// Discovers the virtual camera's hidden CMIO sink stream and enqueues
/// CMSampleBuffers into its CMSimpleQueue.
///
/// Queue depth in the extension is one frame. When full, this writer drops the
/// incoming frame rather than accumulating latency.
final class CMIOSinkWriter {
    enum SinkError: LocalizedError {
        case cameraNotFound(String)
        case deviceNotFound
        case sinkStreamNotFound
        case queueCopy(OSStatus)
        case start(OSStatus)

        var errorDescription: String? {
            switch self {
            case .cameraNotFound(let name): "Virtual camera not found: \(name)"
            case .deviceNotFound: "CMIO device matching virtual camera UID not found"
            case .sinkStreamNotFound: "CMIO sink stream not found"
            case .queueCopy(let s): "CMIOStreamCopyBufferQueue failed: \(s)"
            case .start(let s): "CMIODeviceStartStream failed: \(s)"
            }
        }
    }

    private let cameraName: String
    private var deviceID: CMIODeviceID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?

    init(cameraName: String) {
        self.cameraName = cameraName
    }

    func open() throws {
        guard let captureDevice = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown],
            mediaType: .video,
            position: .unspecified
        ).devices.first(where: { $0.localizedName == cameraName }) else {
            throw SinkError.cameraNotFound(cameraName)
        }

        guard let cmioDevice = try findCMIODevice(uniqueID: captureDevice.uniqueID) else {
            throw SinkError.deviceNotFound
        }
        deviceID = cmioDevice

        let streams = try getStreams(deviceID: deviceID)
        guard let sink = streams.last, streams.count >= 2 else {
            throw SinkError.sinkStreamNotFound
        }
        streamID = sink

        let callback: CMIODeviceStreamQueueAlteredProc = { _, _, _ in
            // Queue availability changed. MVP is push-only and checks capacity
            // before every enqueue, so no wakeup work is required here.
        }

        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(
            streamID,
            callback,
            nil,
            &unmanagedQueue
        )
        guard copyStatus == noErr, let unmanagedQueue else {
            throw SinkError.queueCopy(copyStatus)
        }
        queue = unmanagedQueue.takeUnretainedValue()

        let startStatus = CMIODeviceStartStream(deviceID, streamID)
        guard startStatus == noErr else {
            queue = nil
            throw SinkError.start(startStatus)
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let queue else { return }
        guard CMSimpleQueueGetFullness(queue) < 1.0 else {
            return // latest-frame-wins: drop instead of building latency
        }
        let ptr = Unmanaged.passRetained(sampleBuffer).toOpaque()
        let status = CMSimpleQueueEnqueue(queue, element: ptr)
        if status != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(ptr).release()
        }
    }

    func close() {
        if deviceID != 0, streamID != 0 {
            CMIODeviceStopStream(deviceID, streamID)
        }
        queue = nil
        deviceID = 0
        streamID = 0
    }

    deinit { close() }

    private func findCMIODevice(uniqueID: String) throws -> CMIODeviceID? {
        for id in try getDeviceIDs() {
            if try getDeviceUID(deviceID: id) == uniqueID {
                return id
            }
        }
        return nil
    }

    private func getDeviceIDs() throws -> [CMIODeviceID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        try check(CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address, 0, nil, &dataSize
        ))

        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var devices = [CMIODeviceID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        try devices.withUnsafeMutableBytes { raw in
            try check(CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject),
                &address, 0, nil,
                dataSize, &dataUsed, raw.baseAddress
            ))
        }
        return devices
    }

    private func getDeviceUID(deviceID: CMIODeviceID) throws -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        try check(CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize))

        var value: Unmanaged<CFString>?
        var dataUsed: UInt32 = 0
        try withUnsafeMutablePointer(to: &value) { ptr in
            try check(CMIOObjectGetPropertyData(
                deviceID, &address, 0, nil,
                dataSize, &dataUsed, ptr
            ))
        }
        return value?.takeUnretainedValue() as String?
    }

    private func getStreams(deviceID: CMIODeviceID) throws -> [CMIOStreamID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        try check(CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize))

        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streams = [CMIOStreamID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        try streams.withUnsafeMutableBytes { raw in
            try check(CMIOObjectGetPropertyData(
                deviceID, &address, 0, nil,
                dataSize, &dataUsed, raw.baseAddress
            ))
        }
        return streams
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
