import Foundation
import CoreVideo
import CoreMedia

/// Simple CPU-generated diagnostic source.
/// This is deliberately not performance-critical; it exists so Camera Extension,
/// signing and CMIO sink wiring can be tested before Syphon is installed.
final class TestPatternSource {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private let queue = DispatchQueue(label: "syphon-camera.test-pattern")
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frameIndex: UInt64 = 0

    func start() throws {
        var pool: CVPixelBufferPool?
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: Int(CameraConstants.width),
            kCVPixelBufferHeightKey: Int(CameraConstants.height),
            kCVPixelBufferPixelFormatTypeKey: CameraConstants.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault, nil, attrs as CFDictionary, &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(domain: "TestPattern", code: Int(status))
        }
        self.pool = pool

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(Int(1_000_000_000 / CameraConstants.fps)),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        pool = nil
    }

    private func tick() {
        guard let pool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pool, &buffer
        ) == kCVReturnSuccess, let buffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = Int(CameraConstants.width)
        let height = Int(CameraConstants.height)
        let p = base.assumingMemoryBound(to: UInt8.self)

        let barX = Int(frameIndex % UInt64(width))
        for y in 0..<height {
            let row = p.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let i = x * 4
                let bright = abs(x - barX) < 10
                row[i + 0] = bright ? 255 : UInt8((x * 255) / max(1, width - 1))
                row[i + 1] = UInt8((y * 255) / max(1, height - 1))
                row[i + 2] = bright ? 255 : 32
                row[i + 3] = 255
            }
        }

        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CameraConstants.fps)
        frameIndex += 1
        onFrame?(buffer, pts)
    }
}
