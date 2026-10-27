// Read-only discovery: this program never requests permission, creates a capture
// input/session, or opens any physical or virtual camera stream.
import AVFoundation
import CoreMedia
import Foundation

func fourCC(_ value: FourCharCode) -> String {
    let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
    return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", value)
}

let expectedName = "Dream Jack Camera Probe"
let deviceTypes: [AVCaptureDevice.DeviceType]
if #available(macOS 14.0, *) {
    deviceTypes = [.external]
} else {
    deviceTypes = [.externalUnknown]
}
let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: deviceTypes,
    mediaType: .video,
    position: .unspecified
)
let matches = discovery.devices.filter { $0.localizedName == expectedName }
let cameras: [[String: Any]] = matches.map { camera in
    let formats: [[String: Any]] = camera.formats.map { format in
        let description = format.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        return [
            "width": Int(dimensions.width),
            "height": Int(dimensions.height),
            "mediaSubtype": fourCC(CMFormatDescriptionGetMediaSubType(description)),
            "frameRateRanges": format.videoSupportedFrameRateRanges.map {
                ["minimum": $0.minFrameRate, "maximum": $0.maxFrameRate]
            }
        ]
    }
    return [
        "name": camera.localizedName,
        "uniqueID": camera.uniqueID,
        "modelID": camera.modelID,
        "deviceType": camera.deviceType.rawValue,
        "formats": formats
    ]
}
let report: [String: Any] = [
    "expectedName": expectedName,
    "status": matches.isEmpty ? "not_found" : "found",
    "matchingCameraCount": matches.count,
    "cameras": cameras,
    "captureStarted": false,
    "permissionRequested": false
]
do {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Unable to encode camera discovery: \(error)\n".utf8))
    exit(2)
}
exit(matches.isEmpty ? 1 : 0)
