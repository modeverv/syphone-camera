import Foundation
import CoreVideo
import Darwin

// Standalone correctness check, never part of the performance sample. Its CPU
// pixel readback deliberately verifies that both transport modes emit identical
// images for the same input. It opens no camera and installs no application.
@main
enum RendererComparisonCheck {
    static func compare(_ direct: CVPixelBuffer, _ copied: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(direct)
        let height = CVPixelBufferGetHeight(direct)
        guard width == CVPixelBufferGetWidth(copied), height == CVPixelBufferGetHeight(copied),
              CVPixelBufferGetPixelFormatType(direct) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(copied) == kCVPixelFormatType_32BGRA else {
            throw NativeCameraError.message("Renderer formats differ")
        }
        guard CVPixelBufferLockBaseAddress(direct, .readOnly) == kCVReturnSuccess else {
            throw NativeCameraError.message("Cannot lock direct pixels")
        }
        defer { CVPixelBufferUnlockBaseAddress(direct, .readOnly) }
        guard CVPixelBufferLockBaseAddress(copied, .readOnly) == kCVReturnSuccess else {
            throw NativeCameraError.message("Cannot lock copied pixels")
        }
        defer { CVPixelBufferUnlockBaseAddress(copied, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddress(direct), let b = CVPixelBufferGetBaseAddress(copied) else {
            throw NativeCameraError.message("Missing pixel base address")
        }
        for row in 0..<height {
            let ap = a.advanced(by: row * CVPixelBufferGetBytesPerRow(direct))
            let bp = b.advanced(by: row * CVPixelBufferGetBytesPerRow(copied))
            guard memcmp(ap, bp, width * 4) == 0 else {
                throw NativeCameraError.message("Pixel mismatch at row \(row)")
            }
        }
    }

    static func main() {
        do {
            let direct = try SurfacePatternRenderer(mode: .zeroCopy)
            let copied = try SurfacePatternRenderer(mode: .gpuCopy)
            let sequences: [UInt64] = [1, 255, 256, 0xFEDC_BA98_7654_3210]
            for sequence in sequences {
                try autoreleasepool {
                    guard let a = try direct.render(sequence: sequence),
                          let b = try copied.render(sequence: sequence) else {
                        throw NativeCameraError.message("Unexpected pool pressure during equality check")
                    }
                    try compare(a, b)
                }
            }
            let a = direct.performanceSnapshot
            let b = copied.performanceSnapshot
            guard (a["transportPixelCopies"] as? UInt64) == 0,
                  (b["transportPixelCopies"] as? UInt64) == UInt64(sequences.count),
                  direct.seenSurfaceIDs.count <= SurfacePatternRenderer.poolLimit,
                  copied.seenSurfaceIDs.count <= SurfacePatternRenderer.poolLimit else {
                throw NativeCameraError.message("Copy count or final surface pool contract failed")
            }
            let result: [String: Any] = ["status": "passed", "cameraOpened": false,
                "comparison": "all BGRA pixel bytes, excluding row padding",
                "sequenceCases": sequences.map(String.init), "width": 1920, "height": 1080,
                "zeroCopy": a, "gpuCopy": b,
                "timingsAreBenchmark": false]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        } catch {
            FileHandle.standardError.write(Data("FAILED: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
