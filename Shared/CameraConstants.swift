import Foundation
import CoreVideo
import CoreMedia

enum CameraConstants {
    static let appBundleID = "com.example.SyphonCamera"
    static let extensionBundleID = "com.example.SyphonCamera.CameraExtension"
    static let appGroupID = "group.com.example.SyphonCamera"

    static let cameraName = "Syphon Camera"
    static let sourceStreamName = "Syphon Camera Video"
    static let sinkStreamName = "Syphon Camera Input"

    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let fps: Int32 = 30
    static let pixelFormat: OSType = kCVPixelFormatType_32BGRA
    static let frameDuration = CMTime(value: 1, timescale: fps)

    // Stable IDs make device discovery deterministic across runs.
    static let deviceUUID = UUID(uuidString: "B42168C5-5C8A-4C62-AE9A-7CDCF0469191")!
    static let sourceStreamUUID = UUID(uuidString: "6839517D-404E-474C-840E-973FE427A1C1")!
    static let sinkStreamUUID = UUID(uuidString: "4E8DF3D4-61A7-4EE6-9B5B-7F5EE91F0A10")!
}
