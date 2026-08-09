import Foundation
import Network
import CoreVideo
import CoreMedia
import Metal
import os
import VideoToolbox

final class NetworkFrameSource: FrameSource {
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "local.syphon-unicamex.network-receiver")
    private let queueKey = DispatchSpecificKey<Void>()
    private let width: Int
    private let height: Int
    private let transport: NetworkTransport
    private var listener: NWListener?
    private var latest: CMSampleBuffer?
    private var latestPublishedAt: UInt64?
    private var receiveBuffer = Data()
    private var isReceiving = false
    private var decoder: H264HardwareDecoder?
    private var loggedDecodedFrame = false
    private var loggedPacket = false
    private var udpFrames: [UInt32: UDPFrameAssembly] = [:]

    var isActive = false

    init(width: Int, height: Int, fps: Int, port: UInt16 = 5001, transport: NetworkTransport = .tcp) {
        self.width = width
        self.height = height
        self.port = NWEndpoint.Port(rawValue: port) ?? 5000
        self.transport = transport
        _ = fps
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: transport == .udp ? .udp : .tcp, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.handleListenerFailure() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        decoder = H264HardwareDecoder(width: width, height: height) { [weak self] pixelBuffer, presentationTime in
            guard let self else { return }
            // VideoToolbox invokes this on its own callback thread. Keep all source
            // state on the receiver queue so BridgeEngine's synchronous reads cannot
            // race publication while a TCP packet is being consumed.
            self.queue.async { [weak self] in
                guard let self else { return }
                do {
                    self.latest = try SampleBufferFactory.makeSampleBuffer(from: pixelBuffer, presentationTime: presentationTime)
                    self.latestPublishedAt = mach_absolute_time()
                    if !self.loggedDecodedFrame {
                        self.loggedDecodedFrame = true
                        os_log("Network receiver first decoded BGRA frame: %{public}dx%{public}d", CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
                    }
                } catch { os_log("Decoded frame sample creation failed: %{public}@", error.localizedDescription) }
            }
        }
        isActive = true
        listener.start(queue: queue)
        os_log("Network frame receiver listening on %{public}@ %{public}@", transport.rawValue.uppercased(), port.rawValue.description)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isActive = false
        let clearState = {
            self.isReceiving = false
            self.receiveBuffer.removeAll(keepingCapacity: true)
            self.udpFrames.removeAll(keepingCapacity: true)
            self.latest = nil
            self.latestPublishedAt = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { clearState() }
        else { queue.sync(execute: clearState) }
    }

    private func handleListenerFailure() {
        listener = nil
        isActive = false
        isReceiving = false
        receiveBuffer.removeAll(keepingCapacity: true)
        os_log("Network frame receiver stopped after listener failure")
    }

    func latestTexture() -> MTLTexture? { nil }
    var latestTexturePublishedAt: UInt64? { queue.sync { latestPublishedAt } }
    func latestSampleBuffer() -> CMSampleBuffer? { queue.sync { latest } }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .ready = state {
                if self?.transport == .udp { self?.receiveDatagram(from: connection) }
                else { self?.receive(from: connection) }
            }
        }
        connection.start(queue: queue)
    }

    private func receive(from connection: NWConnection?) {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2_000_000) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consumeTCP(data) }
            if !isComplete, error == nil { self.receive(from: connection) }
        }
    }

    private func receiveDatagram(from connection: NWConnection?) {
        guard let connection else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consumeUDP(data) }
            if error == nil { self.receiveDatagram(from: connection) }
        }
    }

    private func consumeTCP(_ data: Data) {
        receiveBuffer.append(data)
        if !loggedPacket {
            loggedPacket = true
            os_log("Network receiver first TCP bytes: %{public}d buffered=%{public}d", data.count, receiveBuffer.count)
        }
        while receiveBuffer.count >= NetworkFrameHeader.byteCount {
            let packetStart = receiveBuffer.startIndex
            let headerEnd = receiveBuffer.index(packetStart, offsetBy: NetworkFrameHeader.byteCount)
            guard let header = NetworkFrameHeader(data: receiveBuffer[packetStart..<headerEnd]) else {
                receiveBuffer.removeFirst()
                continue
            }
            // H.264 payload size varies per frame; only reject invalid dimensions or
            // packets beyond the bounded receive allocation.
            guard header.width == width, header.height == height,
                  header.payloadSize > 4, header.payloadSize <= 2_000_000 else {
                receiveBuffer.removeFirst()
                continue
            }
            let payloadLength = Int(header.payloadSize)
            // Avoid a potentially invalid Data subrange even if a malformed stream
            // happens to contain the header magic while resynchronising.
            guard payloadLength <= receiveBuffer.count - NetworkFrameHeader.byteCount else { return }
            let payloadEnd = receiveBuffer.index(headerEnd, offsetBy: payloadLength)
            let payload = receiveBuffer.subdata(in: headerEnd..<payloadEnd)
            receiveBuffer.removeFirst(NetworkFrameHeader.byteCount + payloadLength)
            do { try decode(payload: payload, timestampNanoseconds: header.timestampNanoseconds) }
            catch { os_log("Network frame rejected: %{public}@", error.localizedDescription) }
        }
    }

    private func consumeUDP(_ datagram: Data) {
        guard let header = UDPFragmentHeader(data: datagram),
              header.fragmentCount > 0, header.fragmentIndex < header.fragmentCount,
              Int(header.payloadSize) == datagram.count - UDPFragmentHeader.byteCount else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        udpFrames = udpFrames.filter { now - $0.value.createdAt < 1_000_000_000 }
        var assembly = udpFrames[header.frameID] ?? UDPFrameAssembly(fragmentCount: Int(header.fragmentCount), createdAt: now)
        guard assembly.fragments.count == Int(header.fragmentCount) else { return }
        assembly.fragments[Int(header.fragmentIndex)] = datagram.subdata(in: UDPFragmentHeader.byteCount..<datagram.endIndex)
        if assembly.fragments.allSatisfy({ $0 != nil }) {
            let packet = assembly.fragments.compactMap { $0 }.reduce(into: Data(), { $0.append($1) })
            udpFrames.removeValue(forKey: header.frameID)
            consumeTCP(packet)
        } else {
            udpFrames[header.frameID] = assembly
        }
    }

    private func decode(payload: Data, timestampNanoseconds: UInt64) throws {
        guard payload.count >= 4 else { throw BridgeError.noFrameAvailable }
        let parameterLength = Int(payload[0]) << 24 | Int(payload[1]) << 16 | Int(payload[2]) << 8 | Int(payload[3])
        guard parameterLength >= 0, payload.count > 4 + parameterLength else { throw BridgeError.noFrameAvailable }
        let parameterSets = payload.subdata(in: 4..<(4 + parameterLength))
        let accessUnit = payload.subdata(in: (4 + parameterLength)..<payload.count)
        os_log("Network receiver H.264 packet: parameterBytes=%{public}d accessUnitBytes=%{public}d", parameterSets.count, accessUnit.count)
        try decoder?.decode(accessUnit: accessUnit, parameterSets: parameterSets,
                             timestamp: CMTime(value: Int64(timestampNanoseconds), timescale: 1_000_000_000))
    }
}

private struct UDPFrameAssembly {
    var fragments: [Data?]
    let createdAt: UInt64

    init(fragmentCount: Int, createdAt: UInt64) {
        fragments = Array(repeating: nil, count: fragmentCount)
        self.createdAt = createdAt
    }
}
