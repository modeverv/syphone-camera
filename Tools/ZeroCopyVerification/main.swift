import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import IOSurface

// This is a verification consumer, not a production image-transfer stage.
// Pixel hashing, stamp checking and PNG export deliberately read pixels here.
// Native capture and surface/PTS correlation do not need those readbacks.

struct Options {
    var name = "Syphon Zero Copy Camera"
    var uniqueID: String?
    var width: Int?
    var height: Int?
    var report = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zero-copy-verification.json")
    var sourceTrace: URL?
    var firstPNG: URL?
    var duration: Double = 10
    var maxFrames = 600
    var minimumFrames = 1
    var authorizationTimeout: Double = 90
    var hashPixels = false
    var validateStamp = false
    var holdMilliseconds = 0
    var maximumHeldBuffers = 3
    var readPixels: Bool { hashPixels || validateStamp || holdMilliseconds > 0 }

    init(arguments: [String]) throws {
        var index = 0
        func next(_ key: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw Failure("Missing value for \(key)") }
            return arguments[index]
        }
        while index < arguments.count {
            let key = arguments[index]
            switch key {
            case "--name": name = try next(key)
            case "--unique-id": uniqueID = try next(key)
            case "--width":
                guard let n = Int(try next(key)), (1...16384).contains(n) else { throw Failure("width must be in 1...16384") }; width = n
            case "--height":
                guard let n = Int(try next(key)), (1...16384).contains(n) else { throw Failure("height must be in 1...16384") }; height = n
            case "--report": report = URL(fileURLWithPath: try next(key))
            case "--source-trace": sourceTrace = URL(fileURLWithPath: try next(key))
            case "--first-png": firstPNG = URL(fileURLWithPath: try next(key))
            case "--duration":
                guard let n = Double(try next(key)), n.isFinite, n > 0, n <= 300 else { throw Failure("duration must be in (0, 300]") }; duration = n
            case "--max-frames":
                guard let n = Int(try next(key)), (1...10000).contains(n) else { throw Failure("max-frames must be in 1...10000") }; maxFrames = n
            case "--minimum-frames":
                guard let n = Int(try next(key)), (1...10000).contains(n) else { throw Failure("minimum-frames must be in 1...10000") }; minimumFrames = n
            case "--authorization-timeout":
                guard let n = Double(try next(key)), n.isFinite, n >= 1, n <= 300 else { throw Failure("authorization-timeout must be in 1...300") }; authorizationTimeout = n
            case "--hash-pixels": hashPixels = true
            case "--validate-stamp": validateStamp = true
            case "--hold-ms":
                guard let n = Int(try next(key)), (0...1000).contains(n) else { throw Failure("hold-ms must be in 0...1000") }; holdMilliseconds = n
            case "--hold-count":
                guard let n = Int(try next(key)), (1...8).contains(n) else { throw Failure("hold-count must be in 1...8") }; maximumHeldBuffers = n
            case "--help", "-h": throw Failure(Self.usage)
            default: throw Failure("Unknown argument: \(key)\n\(Self.usage)")
            }
            index += 1
        }
        guard !name.isEmpty, minimumFrames <= maxFrames else { throw Failure("Invalid camera name or minimum-frames exceeds max-frames") }
        guard (width == nil) == (height == nil) else { throw Failure("--width and --height must be provided together") }
    }

    static let usage = """
    ZeroCopyVerifier [--name exactName | --unique-id exactID] --report /absolute/result.json
      [--duration 10] [--max-frames 600] [--minimum-frames 1]
      [--width 1280 --height 720]
      [--source-trace submitted.jsonl] [--hash-pixels] [--validate-stamp]
      [--hold-ms 200] [--hold-count 3] [--first-png /absolute/first.png]
      [--authorization-timeout 90]
    A name must match exactly and uniquely; there is no default-device fallback.
    Default format selection preserves the camera's current native format.
    Width/height select an advertised native format; no output resizing is requested.
    Pixel reads happen only when hashing, stamp checking, holding or PNG export is enabled.
    """
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

func fourCC(_ value: FourCharCode) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }, encoding: .ascii) ?? String(format: "0x%08x", value)
}

func timeJSON(_ time: CMTime) -> [String: Any] {
    var result: [String: Any] = ["value": time.value, "timescale": time.timescale, "epoch": time.epoch, "flags": time.flags.rawValue]
    let seconds = CMTimeGetSeconds(time)
    if seconds.isFinite { result["seconds"] = seconds }
    return result
}

private struct NativeVideoFormat: Equatable {
    let width: Int
    let height: Int
    let pixelFormat: FourCharCode

    init(_ description: CMFormatDescription) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        width = Int(dimensions.width)
        height = Int(dimensions.height)
        pixelFormat = CMFormatDescriptionGetMediaSubType(description)
    }

    var json: [String: Any] {
        ["width": width, "height": height, "pixelFormat": fourCC(pixelFormat), "pixelFormatCode": pixelFormat]
    }

    // macOS does not expose AVCaptureSession.Preset.inputPriority. Match the
    // session preset to the selected format so its default .high cannot request
    // 1080p from a producer that is already streaming 720p.
    var matchingPreset: AVCaptureSession.Preset? {
        switch (width, height) {
        case (1920, 1080): return .hd1920x1080
        case (1280, 720): return .hd1280x720
        case (640, 480): return .vga640x480
        default: return nil
        }
    }

    func matches(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height &&
            CVPixelBufferGetPixelFormatType(buffer) == pixelFormat
    }
}

// Exact rational keys avoid rounding PTS to nanoseconds or matching reused IDs alone.
func rationalKey(value: Int64, scale: Int32, epoch: Int64 = 0) -> String? {
    guard scale > 0, value != Int64.min else { return nil }
    var a = abs(value), b = Int64(scale)
    while b != 0 { let r = a % b; a = b; b = r }
    let divisor = max(a, 1)
    return "\(epoch):\(value / divisor)/\(Int64(scale) / divisor)"
}

struct PixelEvidence {
    var sha256: String?
    var stampSequence: UInt64?
    var stampValid: Bool?
    var error: String?
}

func inspectPixels(_ buffer: CVPixelBuffer, hash: Bool, stamp: Bool) -> PixelEvidence {
    var result = PixelEvidence()
    let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
    guard status == kCVReturnSuccess else { result.error = "CVPixelBufferLockBaseAddress: \(status)"; return result }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let planeCount = CVPixelBufferGetPlaneCount(buffer)
    if hash {
        var digest = SHA256()
        let count = max(planeCount, 1)
        for plane in 0..<count {
            let base = planeCount == 0 ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            let stride = planeCount == 0 ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let height = planeCount == 0 ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetHeightOfPlane(buffer, plane)
            guard let base, stride > 0, height > 0, stride <= Int.max / height else { result.error = "Invalid pixel plane"; return result }
            digest.update(data: Data(bytesNoCopy: base, count: stride * height, deallocator: .none))
        }
        result.sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    if stamp {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(buffer) >= 8, planeCount == 0,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            result.stampValid = false; result.error = "Stamp requires at least eight BGRA pixels"; return result
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sequence: UInt64 = 0
        var valid = true
        for index in 0..<8 {
            sequence |= UInt64(bytes[index * 4]) << (index * 8)
            valid = valid && bytes[index * 4 + 1] == 0x5a && bytes[index * 4 + 2] == 0xa5 && bytes[index * 4 + 3] == 0xff
        }
        result.stampSequence = sequence
        result.stampValid = valid
    }
    return result
}

final class Verifier: NSObject, NSApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let options: Options
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "ZeroCopyVerifier.session")
    private let frameQueue = DispatchQueue(label: "ZeroCopyVerifier.frames")
    private var camera: AVCaptureDevice?
    // Mutable verification state is confined to frameQueue.
    private var frames: [[String: Any]] = []
    private var retentionChecks: [[String: Any]] = []
    private var dropped = 0
    private var pixelReadErrors = 0
    private var nonImageSamples = 0
    private var formatMismatchFrames = 0
    private var expectedFormat: NativeVideoFormat?
    private var pendingHolds = 0
    private var finishRequested = false
    private var captureStopped = false
    private var published = false
    private var startedAt: Double?
    private var finishedAt: Double?
    private var failure: String?
    private var finishReason = ""
    private var pngSaved = false
    private var selectedCamera: [String: Any] = [:]
    private var actualSessionPreset = "unconfigured"
    private var actualOutputSettings = "unconfigured"
    private var initialAuthorization = "unknown"
    private let launchedAt = ISO8601DateFormatter().string(from: Date())

    init(options: Options) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.external] } else { types = [.externalUnknown] }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        let selected = discovery.devices.filter { device in
            if let id = options.uniqueID { return device.uniqueID == id }
            return device.localizedName == options.name
        }
        guard selected.count == 1 else {
            frameQueue.async { self.stop(reason: "selection_failed", error: "Expected exactly one matching external camera, found \(selected.count)") }
            return
        }
        camera = selected[0]
        let device = selected[0]
        selectedCamera = ["name": device.localizedName, "uniqueID": device.uniqueID, "modelID": device.modelID]
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        initialAuthorization = String(status.rawValue)
        switch status {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                if allowed { self.configure() }
                else { self.frameQueue.async { self.stop(reason: "permission_denied", error: "Camera permission was denied") } }
            }
        default:
            frameQueue.async { self.stop(reason: "permission_denied", error: "Camera authorization is denied or restricted") }
        }
        frameQueue.asyncAfter(deadline: .now() + options.authorizationTimeout) {
            if self.startedAt == nil { self.stop(reason: "authorization_timeout", error: "Camera authorization/startup did not finish before timeout") }
        }
    }

    private func configure() {
        sessionQueue.async {
            guard let camera = self.camera else { return }
            do {
                // Read this before configuring a session: the default preset
                // is allowed to replace the device's active format.
                let originalFormat = camera.activeFormat
                let original = NativeVideoFormat(originalFormat.formatDescription)
                let chosenFormat: AVCaptureDevice.Format
                if let width = self.options.width, let height = self.options.height {
                    let candidates = camera.formats.filter {
                        let candidate = NativeVideoFormat($0.formatDescription)
                        return candidate.width == width && candidate.height == height
                    }
                    guard let selected = candidates.first(where: {
                        CMFormatDescriptionGetMediaSubType($0.formatDescription) == original.pixelFormat
                    }) ?? candidates.first else {
                        throw Failure("Camera does not advertise a native \(width)x\(height) format")
                    }
                    chosenFormat = selected
                } else { chosenFormat = originalFormat }
                let expected = NativeVideoFormat(chosenFormat.formatDescription)
                let input = try AVCaptureDeviceInput(device: camera)
                let output = AVCaptureVideoDataOutput()
                // An empty dictionary requests device-native samples. nil does not.
                output.videoSettings = [:]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.frameQueue)
                self.session.beginConfiguration()
                if let preset = expected.matchingPreset {
                    guard self.session.canSetSessionPreset(preset) else {
                        self.session.commitConfiguration()
                        throw Failure("Session cannot preserve the selected \(expected.width)x\(expected.height) native format")
                    }
                    self.session.sessionPreset = preset
                }
                guard self.session.canAddInput(input) else { self.session.commitConfiguration(); throw Failure("Cannot add exact camera input") }
                self.session.addInput(input)
                guard self.session.canAddOutput(output) else { self.session.commitConfiguration(); throw Failure("Cannot add native video output") }
                self.session.addOutput(output)
                self.session.commitConfiguration()
                try camera.lockForConfiguration()
                camera.activeFormat = chosenFormat
                camera.unlockForConfiguration()
                self.frameQueue.sync {
                    self.expectedFormat = expected
                    self.selectedCamera["initialActiveFormat"] = original.json
                    self.selectedCamera["selectedNativeFormat"] = expected.json
                    self.selectedCamera["formatSelection"] = self.options.width == nil ? "preserve_current" : "explicit_native_dimensions"
                }
                self.session.startRunning()
                self.frameQueue.async {
                    guard !self.finishRequested else {
                        self.sessionQueue.async { self.session.stopRunning() }
                        return
                    }
                    self.startedAt = ProcessInfo.processInfo.systemUptime
                    self.actualSessionPreset = self.session.sessionPreset.rawValue
                    self.actualOutputSettings = String(describing: output.videoSettings)
                    let actual = NativeVideoFormat(camera.activeFormat.formatDescription)
                    self.selectedCamera["activeFormat"] = actual.json
                    self.selectedCamera["activeVideoMinFrameDuration"] = timeJSON(camera.activeVideoMinFrameDuration)
                    self.selectedCamera["activeVideoMaxFrameDuration"] = timeJSON(camera.activeVideoMaxFrameDuration)
                    if !self.session.isRunning { self.stop(reason: "start_failed", error: "AVCaptureSession did not start"); return }
                    guard actual == expected else {
                        self.stop(reason: "native_format_changed", error: "Session changed the selected native format: expected \(expected.json), actual \(actual.json)")
                        return
                    }
                    self.frameQueue.asyncAfter(deadline: .now() + self.options.duration) { self.stop(reason: "duration_elapsed") }
                }
            } catch {
                self.frameQueue.async { self.stop(reason: "configuration_failed", error: String(describing: error)) }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        record(sampleBuffer)
    }

    private func record(_ sampleBuffer: CMSampleBuffer) {
        guard !finishRequested else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { nonImageSamples += 1; return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        let surfaceID = surface.map { IOSurfaceGetID($0) } ?? 0
        let seed = surface.map { IOSurfaceGetSeed($0) } ?? 0
        let index = frames.count
        let matchesFormat = expectedFormat?.matches(buffer) == true
        if !matchesFormat {
            formatMismatchFrames += 1
            failure = "Received sample dimensions or pixel format do not match the selected native format"
        }
        var record: [String: Any] = [
            "index": index, "pts": timeJSON(pts), "receivedHostTime": timeJSON(CMClockGetTime(CMClockGetHostTimeClock())),
            "width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
            "pixelFormat": fourCC(CVPixelBufferGetPixelFormatType(buffer)), "pixelFormatCode": CVPixelBufferGetPixelFormatType(buffer),
            "bytesPerRow": CVPixelBufferGetBytesPerRow(buffer), "planeCount": CVPixelBufferGetPlaneCount(buffer),
            "surfaceID": surfaceID, "surfaceSeed": seed, "iosurfaceBacked": surface != nil,
            "nativeFormatMatchesSelection": matchesFormat
        ]
        let shouldHold = options.holdMilliseconds > 0 && pendingHolds < options.maximumHeldBuffers
        let pixels = inspectPixelsIfNeeded(buffer, hash: options.hashPixels || shouldHold, stamp: options.validateStamp)
        if let hash = pixels.sha256 { record["sha256"] = hash }
        if let valid = pixels.stampValid { record["stampValid"] = valid }
        if let seq = pixels.stampSequence { record["stampSequence"] = String(seq) }
        if let error = pixels.error { record["pixelReadError"] = error; pixelReadErrors += 1 }
        if let destination = options.firstPNG, !pngSaved {
            do { try writePNG(buffer, destination: destination); pngSaved = true; record["png"] = destination.path }
            catch { record["pngError"] = String(describing: error); self.failure = "First-frame PNG failed: \(error)" }
        }
        frames.append(record)
        if shouldHold, let beforeHash = pixels.sha256 {
            pendingHolds += 1
            let heldAt = ProcessInfo.processInfo.systemUptime
            frameQueue.asyncAfter(deadline: .now() + .milliseconds(options.holdMilliseconds)) { [buffer] in
                let after = inspectPixels(buffer, hash: true, stamp: self.options.validateStamp)
                let afterSurface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
                let afterSeed = afterSurface.map { IOSurfaceGetSeed($0) } ?? 0
                var check: [String: Any] = [
                    "frameIndex": index, "surfaceID": surfaceID, "pts": timeJSON(pts),
                    "heldMilliseconds": (ProcessInfo.processInfo.systemUptime - heldAt) * 1000,
                    "beforeSHA256": beforeHash, "afterSHA256": after.sha256 ?? "",
                    "beforeSeed": seed, "afterSeed": afterSeed,
                    "pixelsUnchanged": after.sha256 == beforeHash, "seedUnchanged": seed == afterSeed
                ]
                if let error = after.error { check["error"] = error; self.pixelReadErrors += 1 }
                self.retentionChecks.append(check)
                self.pendingHolds -= 1
                self.publishIfReady()
            }
        }
        if frames.count >= options.maxFrames { stop(reason: "maximum_frames") }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { dropped += 1 }

    private func inspectPixelsIfNeeded(_ buffer: CVPixelBuffer, hash: Bool, stamp: Bool) -> PixelEvidence {
        hash || stamp ? inspectPixels(buffer, hash: hash, stamp: stamp) : PixelEvidence()
    }

    private func writePNG(_ buffer: CVPixelBuffer, destination: URL) throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = context.createCGImage(image, from: image.extent) else { throw Failure("Cannot render verification image") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else { throw Failure("Cannot create PNG") }
        CGImageDestinationAddImage(output, cg, nil)
        guard CGImageDestinationFinalize(output) else { throw Failure("Cannot finalize PNG") }
    }

    private func stop(reason: String, error: String? = nil) {
        guard !finishRequested else { return }
        finishRequested = true
        finishReason = reason
        if let error { failure = error }
        finishedAt = ProcessInfo.processInfo.systemUptime
        sessionQueue.async {
            self.session.stopRunning()
            self.frameQueue.async { self.captureStopped = true; self.publishIfReady() }
        }
    }

    private func correlate() -> [String: Any] {
        guard let sourceTrace = options.sourceTrace else { return ["requested": false, "sameSurfaceAndPTSConfirmed": false] }
        do {
            let text = try String(contentsOf: sourceTrace, encoding: .utf8)
            var source: [String: [String: Any]] = [:]
            var malformed = 0
            var duplicates = 0
            for line in text.split(whereSeparator: \.isNewline) {
                guard let data = String(line).data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { malformed += 1; continue }
                guard object["event"] as? String == "submitted" else { continue }
                guard let surface = object["surfaceID"] as? NSNumber, let value = object["ptsValue"] as? NSNumber,
                      let scale = object["ptsTimescale"] as? NSNumber, let timeKey = rationalKey(value: value.int64Value, scale: scale.int32Value) else { malformed += 1; continue }
                let key = "\(surface.uint32Value):\(timeKey)"
                if source[key] != nil { duplicates += 1 }
                source[key] = object
            }
            var matched = 0, missing = 0, stampMismatches = 0
            for index in frames.indices {
                let frame = frames[index]
                let pts = frame["pts"] as? [String: Any] ?? [:]
                guard let value = pts["value"] as? Int64, let scale = pts["timescale"] as? Int32,
                      let surface = frame["surfaceID"] as? UInt32, surface != 0,
                      let key = rationalKey(value: value, scale: scale, epoch: pts["epoch"] as? Int64 ?? 0),
                      let submitted = source["\(surface):\(key)"] else {
                    frames[index]["sourceMatch"] = false; missing += 1; continue
                }
                frames[index]["sourceMatch"] = true
                matched += 1
                if let sequence = submitted["sequence"] as? NSNumber {
                    frames[index]["sourceSequence"] = sequence.stringValue
                    if options.validateStamp {
                        let agrees = frame["stampValid"] as? Bool == true && frame["stampSequence"] as? String == sequence.stringValue
                        frames[index]["stampMatchesSourceSequence"] = agrees
                        if !agrees { stampMismatches += 1 }
                    }
                } else if options.validateStamp { stampMismatches += 1; frames[index]["stampMatchesSourceSequence"] = false }
            }
            return ["requested": true, "path": sourceTrace.path, "sourceRecords": source.count,
                    "malformedSourceLines": malformed, "duplicateSurfacePTSKeys": duplicates,
                    "matchedFrames": matched, "unmatchedFrames": missing, "stampSequenceMismatches": stampMismatches,
                    "matchingRule": "same IOSurface ID and exactly equal rational PTS",
                    "sameSurfaceAndPTSConfirmed": !frames.isEmpty && missing == 0 && stampMismatches == 0 && malformed == 0 && duplicates == 0]
        } catch { return ["requested": true, "error": String(describing: error), "sameSurfaceAndPTSConfirmed": false] }
    }

    private func publishIfReady() {
        guard finishRequested, captureStopped, pendingHolds == 0, !published else { return }
        published = true
        let correlation = correlate()
        let surfaceIDs = Set(frames.compactMap { ($0["surfaceID"] as? UInt32).flatMap { $0 == 0 ? nil : $0 } })
        let hashes = Set(frames.compactMap { $0["sha256"] as? String })
        let stamps = Set(frames.compactMap { $0["stampSequence"] as? String })
        let mutations = retentionChecks.filter { $0["pixelsUnchanged"] as? Bool != true }.count
        let invalidStamps = frames.filter { $0["stampValid"] as? Bool != true }.count
        let missingSurfaces = frames.filter { $0["iosurfaceBacked"] as? Bool != true }.count
        let passed = failure == nil && frames.count >= options.minimumFrames && missingSurfaces == 0 && pixelReadErrors == 0 && mutations == 0 && formatMismatchFrames == 0
            && (!options.validateStamp || invalidStamps == 0)
            && (options.sourceTrace == nil || correlation["sameSurfaceAndPTSConfirmed"] as? Bool == true)
        var report: [String: Any] = [
            "schemaVersion": 1, "status": passed ? "passed" : "failed", "launchedAt": launchedAt,
            "finishedAt": ISO8601DateFormatter().string(from: Date()), "finishReason": finishReason,
            "camera": selectedCamera, "initialCameraAuthorizationRawValue": initialAuthorization,
            "nativeOutputRequested": true, "requestedVideoSettings": [:] as [String: Any],
            "actualOutputSettings": actualOutputSettings, "sessionPreset": actualSessionPreset,
            "requestedDurationSeconds": options.duration, "receivedFrames": frames.count, "droppedFrames": dropped,
            "nonImageSamples": nonImageSamples, "minimumFrames": options.minimumFrames,
            "formatMismatchFrames": formatMismatchFrames,
            "uniqueSurfaceIDs": surfaceIDs.sorted(), "missingIOSurfaceFrames": missingSurfaces,
            "uniqueSHA256Count": hashes.count, "uniqueStampSequenceCount": stamps.count,
            "pixelReadErrors": pixelReadErrors, "pixelReadbackEnabled": options.readPixels || options.firstPNG != nil,
            "readbackScope": "verification consumer only; not part of the production transfer",
            "hashScope": "native pixel plane bytes including row padding, excluding allocator tail",
            "stampValidationEnabled": options.validateStamp, "invalidStampFrames": options.validateStamp ? invalidStamps : 0,
            "retentionHoldMilliseconds": options.holdMilliseconds, "maximumHeldBuffers": options.maximumHeldBuffers,
            "retentionChecks": retentionChecks, "retentionMutations": mutations,
            "sourceCorrelation": correlation, "frames": frames,
            "interpretation": "Surface+PTS correlation establishes sharing for the traced source-to-this-consumer path. It does not prove unrelated applications or untraced upstream producers avoid copies."
        ]
        if let expectedFormat { report["expectedNativeFormat"] = expectedFormat.json }
        if let width = options.width, let height = options.height {
            report["requestedNativeDimensions"] = ["width": width, "height": height]
        }
        if let startedAt, let finishedAt { report["captureDurationSeconds"] = max(0, finishedAt - startedAt) }
        if let failure { report["error"] = failure }
        if let png = options.firstPNG { report["firstPNG"] = ["path": png.path, "saved": pngSaved] }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: options.report.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: options.report, options: .atomic)
            FileHandle.standardOutput.write(Data("\(passed ? "PASS" : "FAIL"): \(frames.count) frames, \(surfaceIDs.count) IOSurfaces, report=\(options.report.path)\n".utf8))
            DispatchQueue.main.async { exit(passed ? 0 : 1) }
        } catch {
            FileHandle.standardError.write(Data("Cannot write verification report: \(error)\n".utf8))
            DispatchQueue.main.async { exit(2) }
        }
    }

    static func runSelfTests() throws {
        func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else { throw Failure("Self-test failed: \(name)") }
        }
        try check(rationalKey(value: 1, scale: 30) == rationalKey(value: 100, scale: 3000), "equal rational PTS")
        try check(rationalKey(value: 1, scale: 30) != rationalKey(value: 1, scale: 31), "unequal rational PTS")
        try check(rationalKey(value: 1, scale: 0) == nil, "invalid PTS rejected")
        let selectedOptions = try Options(arguments: ["--width", "1280", "--height", "720"])
        try check(selectedOptions.width == 1280 && selectedOptions.height == 720, "paired native dimensions")
        let defaultOptions = try Options(arguments: [])
        try check(defaultOptions.width == nil && defaultOptions.height == nil, "default preserves current format")
        var incompleteDimensionsRejected = false
        do { _ = try Options(arguments: ["--width", "1280"]) }
        catch { incompleteDimensionsRejected = true }
        try check(incompleteDimensionsRejected, "incomplete dimensions rejected")

        func nativeSample(width: Int, height: Int) throws -> CMSampleBuffer {
            var buffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
            let pixelStatus = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
            guard pixelStatus == kCVReturnSuccess, let buffer else { throw Failure("Native format test buffer: \(pixelStatus)") }
            var description: CMVideoFormatDescription?
            let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                                           formatDescriptionOut: &description)
            guard formatStatus == noErr, let description else { throw Failure("Native format test description: \(formatStatus)") }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                           presentationTimeStamp: CMTime(value: 1, timescale: 30), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample)
            guard sampleStatus == noErr, let sample else { throw Failure("Native format test sample: \(sampleStatus)") }
            return sample
        }
        let sample720 = try nativeSample(width: 1280, height: 720)
        let sample1080 = try nativeSample(width: 1920, height: 1080)
        let dimensionVerifier = Verifier(options: selectedOptions)
        dimensionVerifier.expectedFormat = NativeVideoFormat(CMSampleBufferGetFormatDescription(sample720)!)
        dimensionVerifier.record(sample720)
        try check(dimensionVerifier.frames.count == 1 && dimensionVerifier.formatMismatchFrames == 0 && dimensionVerifier.failure == nil,
                  "720p native sample accepted")
        try check(dimensionVerifier.frames[0]["width"] as? Int == 1280 && dimensionVerifier.frames[0]["height"] as? Int == 720,
                  "720p delivered dimensions recorded")
        dimensionVerifier.record(sample1080)
        try check(dimensionVerifier.formatMismatchFrames == 1 && dimensionVerifier.failure != nil &&
                  dimensionVerifier.frames[1]["nativeFormatMatchesSelection"] as? Bool == false,
                  "1080p sample rejected when 720p was selected")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZeroCopyVerifier-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("source.jsonl")
        let line = "{\"event\":\"submitted\",\"sequence\":1,\"surfaceID\":42,\"ptsValue\":100,\"ptsTimescale\":3000}\n"
        try line.write(to: trace, atomically: true, encoding: .utf8)
        let verifier = Verifier(options: try Options(arguments: ["--source-trace", trace.path, "--validate-stamp"]))
        func frame(_ id: UInt32, _ numerator: Int64, _ stamp: String = "1") -> [String: Any] {
            ["surfaceID": id, "pts": timeJSON(CMTime(value: numerator, timescale: 30)), "stampValid": true, "stampSequence": stamp]
        }
        verifier.frames = [frame(42, 1)]
        try check(verifier.correlate()["sameSurfaceAndPTSConfirmed"] as? Bool == true, "exact surface and rational PTS match")
        verifier.frames = [frame(42, 2)]
        try check(verifier.correlate()["sameSurfaceAndPTSConfirmed"] as? Bool == false, "reused surface ID with wrong PTS rejected")
        verifier.frames = [frame(43, 1)]
        try check(verifier.correlate()["sameSurfaceAndPTSConfirmed"] as? Bool == false, "different surface with same PTS rejected")
        verifier.frames = [frame(42, 1, "2")]
        try check(verifier.correlate()["stampSequenceMismatches"] as? Int == 1, "wrong source sequence rejected")
        try (line + line).write(to: trace, atomically: true, encoding: .utf8)
        verifier.frames = [frame(42, 1)]
        try check(verifier.correlate()["sameSurfaceAndPTSConfirmed"] as? Bool == false, "ambiguous duplicate trace keys rejected")

        var optionalBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 4, kCVPixelFormatType_32BGRA, attributes, &optionalBuffer)
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else { throw Failure("Self-test buffer creation: \(status)") }
        try check(CVPixelBufferGetIOSurface(buffer) != nil, "self-test IOSurface backing")
        let sequence: UInt64 = 0xfedcba9876543210
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { CVPixelBufferUnlockBaseAddress(buffer, []); throw Failure("No test pixels") }
        memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<8 {
            bytes[i * 4] = UInt8(truncatingIfNeeded: sequence >> (8 * i))
            bytes[i * 4 + 1] = 0x5a; bytes[i * 4 + 2] = 0xa5; bytes[i * 4 + 3] = 0xff
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let before = inspectPixels(buffer, hash: true, stamp: true)
        try check(before.stampValid == true && before.stampSequence == sequence && before.sha256 != nil, "UInt64 stamp and hash")
        CVPixelBufferLockBaseAddress(buffer, [])
        bytes[1] = 0
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let after = inspectPixels(buffer, hash: true, stamp: true)
        try check(after.stampValid == false && after.sha256 != before.sha256, "stamp corruption and pixel mutation detected")
        print("PASS: native 720p selection/sample checks, rational PTS, source ID/PTS/sequence correlation, duplicate rejection, IOSurface stamp/hash mutation; no camera opened")
    }
}

do {
    if CommandLine.arguments.dropFirst().contains("--help") || CommandLine.arguments.dropFirst().contains("-h") {
        print(Options.usage)
        exit(0)
    }
    if CommandLine.arguments.dropFirst().contains("--self-test") {
        try Verifier.runSelfTests()
        exit(0)
    }
    let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
    let delegate = Verifier(options: options)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}
