import Foundation
import CoreVideo
import CoreMedia

final class TestPatternFrameSource: FrameSource {
    private let width: Int
    private let height: Int
    private let fps: Int
    private let store = LatestFrameStore()
    private let queue = DispatchQueue(label: "local.syphon-unicamex.testpattern")
    private var timer: DispatchSourceTimer?
    private var phase: UInt8 = 0

    var isActive: Bool { timer != nil }

    init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    func start() throws {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(max(1, 1000 / max(1, fps))))
        timer.setEventHandler { [weak self] in self?.generate() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func latestTexture() -> MTLTexture? { nil }
    var latestTexturePublishedAt: UInt64? { nil }
    func latestSampleBuffer() -> CMSampleBuffer? { store.currentSampleBuffer() }

    private func generate() {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pb else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)

        phase &+= 1
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                let moving = UInt8((x + Int(phase) * 4) % 256)
                p.storeBytes(of: moving, as: UInt8.self)
                p.advanced(by: 1).storeBytes(of: UInt8((y * 255) / max(1, height - 1)), as: UInt8.self)
                p.advanced(by: 2).storeBytes(of: UInt8(255 - moving), as: UInt8.self)
                p.advanced(by: 3).storeBytes(of: UInt8(255), as: UInt8.self)
            }
        }

        if let sb = try? SampleBufferFactory.makeSampleBuffer(from: pb) {
            store.publish(sampleBuffer: sb)
        }
    }
}
