import Foundation
import Network
import CoreVideo
import CoreImage
import Metal
import os
import VideoToolbox

/// LAN PoC sender. The transport boundary is intentionally independent from
/// Syphon so its TCP framing can later be replaced by WebRTC/SRT.
final class NetworkFrameSender {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let source: FrameSource
    private let width: Int
    private let height: Int
    private let fps: Int
    private let transport: NetworkTransport
    private let queue = DispatchQueue(label: "local.syphon-unicamex.network-sender")
    private let context = CIContext()
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var sequence: UInt64 = 0
    private var pixelBuffer: CVPixelBuffer?
    private var encoder: H264HardwareEncoder?
    private var loggedEncodedFrame = false
    private var sentBytes: UInt64 = 0
    private var sentFrames = 0
    private var reportStartedAt = DispatchTime.now().uptimeNanoseconds

    init(host: String, port: UInt16 = 5001, transport: NetworkTransport = .tcp, source: FrameSource, width: Int, height: Int, fps: Int) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? 5000
        self.source = source
        self.width = width
        self.height = height
        self.fps = fps
        self.transport = transport
    }

    func start() throws {
        try source.start()
        let connection = NWConnection(host: host, port: port, using: transport == .udp ? .udp : .tcp)
        connection.stateUpdateHandler = { state in
            os_log("Network sender state: %{public}@", String(describing: state))
        }
        self.connection = connection
        connection.start(queue: queue)
        encoder = try H264HardwareEncoder(width: width, height: height, fps: fps) { [weak self] frame in
            if self?.loggedEncodedFrame == false {
                self?.loggedEncodedFrame = true
                os_log("Network sender first H.264 frame: bytes=%{public}d keyframe=%{public}@", frame.data.count, frame.isKeyFrame ? "yes" : "no")
            }
            self?.send(encoded: frame)
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(max(1, 1000 / max(1, fps))))
        timer.setEventHandler { [weak self] in self?.sendLatest() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        source.stop()
    }

    private func sendLatest() {
        guard let connection, case .ready = connection.state else { return }
        do {
            let buffer: CVPixelBuffer
            if let texture = source.latestTexture() {
                buffer = try pixelBuffer(from: texture)
            } else if let sampleBuffer = source.latestSampleBuffer(), let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                buffer = imageBuffer
            } else {
                return
            }
            let timestamp = DispatchTime.now().uptimeNanoseconds
            try encoder?.encode(buffer, timestamp: CMTime(value: Int64(timestamp), timescale: 1_000_000_000))
        } catch {
            os_log("Network sender conversion failed: %{public}@", error.localizedDescription)
        }
    }

    private func send(encoded frame: EncodedVideoFrame) {
        guard let connection, case .ready = connection.state else { return }
        var parameterLength = UInt32(frame.parameterSets.count).bigEndian
        var payload = Data(bytes: &parameterLength, count: 4)
        payload.append(frame.parameterSets)
        payload.append(frame.data)
        let header = NetworkFrameHeader(sequence: sequence,
                                        timestampNanoseconds: UInt64(max(0, frame.timestamp.value)),
                                        width: UInt32(width), height: UInt32(height),
                                        payloadSize: UInt32(payload.count))
        sequence &+= 1
        sentBytes += UInt64(NetworkFrameHeader.byteCount + payload.count)
        sentFrames += 1
        reportIfNeeded()
        let packet = header.encoded() + payload
        if transport == .udp {
            sendUDP(packet, frameID: UInt32(truncatingIfNeeded: sequence))
        } else {
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error { os_log("Network sender dropped encoded frame: %{public}@", error.localizedDescription) }
            })
        }
    }

    private func sendUDP(_ packet: Data, frameID: UInt32) {
        guard let connection else { return }
        let maximumPayload = 1_184 // 16-byte header + 1,184 bytes remains below a 1,200-byte datagram.
        let count = Int(ceil(Double(packet.count) / Double(maximumPayload)))
        guard count > 0, count <= Int(UInt16.max) else { return }
        for index in 0..<count {
            let start = index * maximumPayload
            let end = min(packet.count, start + maximumPayload)
            let header = UDPFragmentHeader(frameID: frameID, fragmentIndex: UInt16(index),
                                           fragmentCount: UInt16(count), payloadSize: UInt16(end - start))
            connection.send(content: header.encoded() + packet.subdata(in: start..<end), completion: .contentProcessed { error in
            if let error { os_log("Network sender dropped encoded frame: %{public}@", error.localizedDescription) }
            })
        }
    }

    private func reportIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - reportStartedAt) / 1_000_000_000
        guard elapsed >= 5 else { return }
        os_log("Network sender stats: fps=%{public}.1f bitrate_mbps=%{public}.2f frames=%{public}d",
               Double(sentFrames) / elapsed, Double(sentBytes * 8) / elapsed / 1_000_000, sentFrames)
        sentBytes = 0
        sentFrames = 0
        reportStartedAt = now
    }

    private func pixelBuffer(from texture: MTLTexture) throws -> CVPixelBuffer {
        if pixelBuffer == nil {
            var created: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
            guard status == kCVReturnSuccess, let created else { throw BridgeError.noFrameAvailable }
            pixelBuffer = created
        }
        guard let pixelBuffer else { throw BridgeError.noFrameAvailable }
        let image = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        guard let image else { throw BridgeError.noFrameAvailable }
        context.render(image, to: pixelBuffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw BridgeError.noFrameAvailable }
        return pixelBuffer
    }
}
