import AppKit
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal
import Syphon

final class RetainedFrameObservation {
    // Hold the actual first texture throughout the observation window. This
    // deliberately tests whether retaining it freezes its producer's pixels.
    let texture: MTLTexture
    let initialSeed: UInt32
    var frameCount = 0
    var surfaceIDs = Set<UInt32>()

    init(texture: MTLTexture, surface: IOSurface) {
        self.texture = texture
        self.initialSeed = IOSurfaceGetSeed(surface)
    }
}

func fourCC(_ value: UInt32) -> String {
    let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
    return String(bytes: bytes, encoding: .ascii) ?? "invalid"
}

func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func inspect(_ surface: IOSurface, label: String) {
    let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
    emit(["event": "surface", "label": label, "id": IOSurfaceGetID(surface),
          "width": width, "height": height, "rowBytes": IOSurfaceGetBytesPerRow(surface),
          "elementBytes": IOSurfaceGetBytesPerElement(surface), "allocation": IOSurfaceGetAllocSize(surface),
          "pixelFormat": IOSurfaceGetPixelFormat(surface), "pixelFormatText": fourCC(IOSurfaceGetPixelFormat(surface)),
          "planeCount": IOSurfaceGetPlaneCount(surface), "seed": IOSurfaceGetSeed(surface)])
    let variants: [(String, [String: Any]?)] = [
        ("nil", nil),
        ("explicit_bgra", [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]),
        ("explicit_bgra_dimensions", [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                       kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height]),
        ("metal", [kCVPixelBufferMetalCompatibilityKey as String: true]),
        ("explicit_bgra_metal", [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                  kCVPixelBufferMetalCompatibilityKey as String: true]),
    ]
    for (variant, attributes) in variants {
        var unmanaged: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, attributes as CFDictionary?, &unmanaged)
        var report: [String: Any] = ["event": "wrap", "label": label, "attributes": variant, "status": status]
        if status == kCVReturnSuccess, let pixelBuffer = unmanaged?.takeRetainedValue() {
            let wrappedSurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
            report["sameSurfaceID"] = wrappedSurface.map { IOSurfaceGetID($0) == IOSurfaceGetID(surface) } ?? false
            report["pixelFormat"] = CVPixelBufferGetPixelFormatType(pixelBuffer)
            var description: CMVideoFormatDescription?
            report["formatStatus"] = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
        }
        emit(report)
    }
}

for format in [UInt32(0), kCVPixelFormatType_32BGRA] {
    var properties: [String: Any] = [kIOSurfaceWidth as String: 640, kIOSurfaceHeight as String: 480,
                                     kIOSurfaceBytesPerElement as String: 4]
    if format != 0 { properties[kIOSurfacePixelFormat as String] = format }
    if let surface = IOSurfaceCreate(properties as CFDictionary) {
        inspect(surface, label: format == 0 ? "synthetic_missing_format" : "synthetic_bgra")
    }
}

if !CommandLine.arguments.contains("--synthetic-only") {
    _ = NSApplication.shared
    guard let device = MTLCreateSystemDefaultDevice() else { exit(2) }
    let directory = SyphonServerDirectory.shared()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
    let servers = directory.servers
    emit(["event": "discovery", "serverCount": servers.count, "servers": servers.map {
        ["app": $0[SyphonServerDescriptionAppNameKey] as? String ?? "",
         "name": $0[SyphonServerDescriptionNameKey] as? String ?? ""]
    }])
    let seenLock = NSLock()
    var observations: [String: RetainedFrameObservation] = [:]
    var clients: [SyphonMetalClient] = []
    for description in servers {
        let appName = description[SyphonServerDescriptionAppNameKey] as? String ?? ""
        let serverName = description[SyphonServerDescriptionNameKey] as? String ?? ""
        let label = appName + "/" + serverName
        let client = SyphonMetalClient(serverDescription: description, device: device, options: nil) { client in
            guard let texture = client.newFrameImage(), let surface = texture.iosurface else {
                emit(["event": "texture_unavailable", "label": label]); return
            }
            seenLock.lock()
            defer { seenLock.unlock() }
            let firstObservation = observations[label] == nil
            let observation = observations[label] ?? RetainedFrameObservation(texture: texture, surface: surface)
            observations[label] = observation
            observation.frameCount += 1
            observation.surfaceIDs.insert(IOSurfaceGetID(surface))
            guard firstObservation else { return }
            emit(["event": "texture", "label": label, "width": texture.width, "height": texture.height,
                  "pixelFormat": texture.pixelFormat.rawValue])
            inspect(surface, label: label)
        }
        clients.append(client)
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
    clients.forEach { $0.stop() }
    seenLock.lock()
    for (label, observation) in observations.sorted(by: { $0.key < $1.key }) {
        guard let retainedSurface = observation.texture.iosurface else { continue }
        let finalSeed = IOSurfaceGetSeed(retainedSurface)
        emit(["event": "retained_texture_observation", "label": label,
              "frameCount": observation.frameCount, "surfaceIDs": observation.surfaceIDs.sorted(),
              "retainedSurfaceID": IOSurfaceGetID(retainedSurface),
              "initialSeed": observation.initialSeed, "finalSeed": finalSeed,
              "seedChangedWhileRetained": observation.initialSeed != finalSeed])
    }
    seenLock.unlock()
}
