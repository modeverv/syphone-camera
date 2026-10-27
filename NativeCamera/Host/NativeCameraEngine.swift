import Foundation
import CoreMedia
import CoreVideo
import IOSurface

final class NativeCameraEngine {
    private let queue = DispatchQueue(label: "com.dream-jack.syphoncamera.producer", qos: .userInitiated)
    private let sink = NativeCameraSink()
    private var timer: DispatchSourceTimer?
    private var renderer: SurfacePatternRenderer?
    private var syphonSource: SyphonResizingSource?
    private var trace: FileHandle?
    private var sequence: UInt64 = 0
    private var submitted: UInt64 = 0
    private var queueDrops: UInt64 = 0
    private var traceLines = 0
    private var tickCount = 0
    private var generation: UInt64 = 0
    private var consecutiveQueueFullTicks = 0
    private var benchmarkMode = false
    private var streamingActivity: NSObjectProtocol?
    private var width = 1920
    private var height = 1080
    let directory: URL
    var statusChanged: ((String) -> Void)?

    init(directory: URL) { self.directory = directory }

    func startPattern(duration: Double? = nil, mode: SurfacePatternRenderer.TransportMode = .zeroCopy,
                      benchmark: Bool = false, width: Int = 1920, height: Int = 1080) {
        start(duration: duration, mode: mode, benchmark: benchmark, width: width, height: height, syphon: false)
    }

    func startSyphon(duration: Double? = nil, benchmark: Bool = false, width: Int = 1920, height: Int = 1080) {
        start(duration: duration, mode: .zeroCopy, benchmark: benchmark, width: width, height: height, syphon: true)
    }

    private func start(duration: Double?, mode: SurfacePatternRenderer.TransportMode,
                       benchmark: Bool, width: Int, height: Int, syphon: Bool) {
        queue.async { [self] in
            stopOnQueue()
            do {
                benchmarkMode = benchmark
                self.width = width; self.height = height
                // Keep a requested real-time stream from being timer-throttled
                // when its host window is obscured. This does not prevent sleep.
                streamingActivity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "Delivering a 30 fps virtual camera stream")
                // Reuse the same bounded pool across stop/start. Buffers retained
                // by an old receiver remain unavailable to this new run.
                if syphon {
                    renderer = nil
                    syphonSource = try SyphonResizingSource(width: width, height: height)
                } else if renderer?.mode != mode || renderer?.width != width || renderer?.height != height {
                    renderer = try SurfacePatternRenderer(mode: mode, width: width, height: height)
                }
                try sink.connect(width: width, height: height)
                let url = directory.appendingPathComponent("source-trace.jsonl")
                try Data().write(to: url)
                trace = try FileHandle(forWritingTo: url)
                sequence = 0; submitted = 0; queueDrops = 0; traceLines = 0; tickCount = 0; consecutiveQueueFullTicks = 0
                write(["event": "start", "source": syphon ? "syphon" : "native-metal-pattern", "poolLimit": SurfacePatternRenderer.poolLimit,
                       "transportMode": mode.rawValue, "benchmarkMode": benchmark,
                       "width": width, "height": height, "frameRate": 30,
                       "sourceGeneration": syphon ? "Latest WMC frame; one GPU resize/flip into owned IOSurface" : "Metal pattern; optional single GPU copy for comparison"])
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 30), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer; timer.resume()
                if let duration, duration > 0 {
                    let startedGeneration = generation
                    queue.asyncAfter(deadline: .now() + duration) { [weak self] in
                        guard let self, self.generation == startedGeneration else { return }
                        self.stopOnQueue(); self.publish("指定時間の送信を完了しました。")
                    }
                }
                publish(syphon ? "WMC映像を \(width)×\(height)・30fps上限で送信しています。" :
                    mode == .zeroCopy ? "GPUテスト映像を直接共有しています。受信アプリでカメラを選択してください。" :
                        "比較測定用: GPUコピーを1回追加して送信しています。")
            } catch { stopOnQueue(); publish(error.localizedDescription) }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue(); publish("停止しました。") } }
    func shutdown() { queue.sync { stopOnQueue(); renderer = nil } }

    private func tick() {
        tickCount += 1
        do {
            if !sink.hasCapacity {
                queueDrops += 1; consecutiveQueueFullTicks += 1
                if consecutiveQueueFullTicks >= 90 {
                    write(["event": "sink_stalled", "action": "reconnect"])
                    try sink.connect(width: width, height: height); consecutiveQueueFullTicks = 0
                }
            }
            else if renderer != nil || syphonSource != nil {
                consecutiveQueueFullTicks = 0
                try autoreleasepool {
                    let nextSequence = sequence + 1
                    let rendered = try syphonSource?.render(sequence: nextSequence) ?? renderer?.render(sequence: nextSequence)
                    guard let buffer = rendered else { return }
                    sequence = nextSequence
                    // CMIO/AVFoundation normalizes output timestamps to 10 us.
                    // Generate an exactly representable timestamp at the source
                    // so source/receiver identity correlation requires no epsilon.
                    let clock = CMClockGetTime(CMClockGetHostTimeClock())
                    let normalized = CMTimeConvertScale(clock, timescale: 100_000, method: .roundTowardZero)
                    let pts = CMTimeConvertScale(normalized, timescale: 1_000_000_000, method: .default)
                    if try sink.submit(buffer, timestamp: pts) {
                        submitted += 1
                        if !benchmarkMode {
                            let surfaceID = IOSurfaceGetID(CVPixelBufferGetIOSurface(buffer)!.takeUnretainedValue())
                            write(["event": "submitted", "sequence": sequence, "surfaceID": surfaceID,
                                   "ptsValue": pts.value, "ptsTimescale": pts.timescale])
                        }
                    } else { queueDrops += 1 }
                }
            }
            if tickCount % 30 == 0 { snapshot() }
        } catch {
            write(["event": "failure", "error": error.localizedDescription])
            stopOnQueue(); publish(error.localizedDescription)
        }
    }

    private func snapshot() {
        if let json = sink.telemetry() {
            try? json.write(to: directory.appendingPathComponent("extension-telemetry.json"), atomically: true, encoding: .utf8)
        }
        var report: [String: Any] = ["submitted": submitted, "queuePressureDrops": queueDrops,
            "recordedAt": ISO8601DateFormatter().string(from: Date()), "running": timer != nil,
            "hostTimeSeconds": CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())),
            "benchmarkMode": benchmarkMode, "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "streamingActivityActive": streamingActivity != nil,
            "poolPressureDrops": syphonSource?.poolPressureDrops ?? renderer?.poolPressureDrops ?? 0,
            "allocatedSurfaceIDs": (syphonSource?.seenSurfaceIDs ?? renderer?.seenSurfaceIDs ?? []).sorted(),
            "poolLimit": SurfacePatternRenderer.poolLimit, "transportPixelCopies": 0,
            "traceLines": traceLines, "traceLimit": 10000]
        if let renderer { report.merge(renderer.performanceSnapshot) { _, new in new } }
        if let syphonSource { report.merge(syphonSource.performanceSnapshot) { _, new in new } }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("producer-status.json"), options: .atomic)
        }
        publish("\(width)×\(height) · 送信 \(submitted) フレーム · 使用バッファ \(syphonSource?.seenSurfaceIDs.count ?? renderer?.seenSurfaceIDs.count ?? 0)/\(SurfacePatternRenderer.poolLimit) · 空き待ち \(queueDrops + (syphonSource?.poolPressureDrops ?? renderer?.poolPressureDrops ?? 0))")
    }

    private func stopOnQueue() {
        generation &+= 1
        timer?.cancel(); timer = nil
        if let streamingActivity {
            ProcessInfo.processInfo.endActivity(streamingActivity)
            self.streamingActivity = nil
        }
        let stopStatus = sink.close()
        if trace != nil {
            snapshot()
            write(["event": "stop", "submitted": submitted, "cmioStopStatus": stopStatus])
        }
        if stopStatus != noErr { publish("CMIO の停止に失敗しました: \(stopStatus)") }
        try? trace?.close(); trace = nil
        syphonSource = nil
    }
    private func write(_ record: [String: Any]) {
        guard traceLines < 10000, let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        try? trace?.write(contentsOf: data + Data([10])); traceLines += 1
    }
    private func publish(_ message: String) {
        let state: [String: Any] = ["recordedAt": ISO8601DateFormatter().string(from: Date()), "message": message]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("host-status.json"), options: .atomic)
        }
        DispatchQueue.main.async { [weak self] in self?.statusChanged?(message) }
    }
}
