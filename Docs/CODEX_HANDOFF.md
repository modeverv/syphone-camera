# Codex Handoff

## Mission

Turn this prototype into a build-clean, signed macOS app that exposes Webcam Motion Capture's Syphon output as `Syphon Camera` with minimal CPU/GPU overhead.

## Success criteria

1. `xcodebuild` succeeds on current Xcode.
2. Camera Extension activates from `/Applications`.
3. `Syphon Camera` appears in QuickTime and Google Meet.
4. Test Pattern produces moving video.
5. Webcam Motion Capture Syphon server can be selected.
6. WMC video appears in Meet.
7. 720p30 bridge uses negligible CPU relative to OBS.
8. No frame queue grows under load.
9. If WMC exits/restarts, reconnect is possible without reinstalling the Camera Extension.

## Work order

### P0 — compile the Camera Extension skeleton

Do this before Syphon.

- Generate Xcode project with XcodeGen or recreate targets using Xcode templates.
- Fix any current Swift 6/CoreMediaIO spelling differences.
- Ensure `CMIOExtensionProvider.startService(provider:)` matches current SDK.
- Ensure source/sink stream protocols conform.
- Fix `CMIOExtensionDeviceProperties.transportType` type if required.
- Install app in `/Applications`.
- Activate extension.
- Verify camera appears.

### P0 — make Test Pattern cross the sink stream

- Run host in Test Pattern mode.
- Make `CMIOSinkWriter` discover the camera and its sink stream.
- Verify CMSimpleQueue ownership rules.
- Instruments: confirm sample buffers are released by CMIO after dequeue.
- If stream ordering is unstable, discover the sink stream using CMIO stream direction properties rather than `streams.last`.

### P0 — Syphon

- Build/link current Syphon framework with Metal support.
- Confirm Swift import module is `Syphon`.
- Confirm methods:
  - `SyphonServerDirectory.shared()`
  - `.servers`
  - `SyphonMetalClient(serverDescription:device:options:newFrameHandler:)`
  - `newFrameImage()`
- Fix Swift bridging names if Xcode imports Objective-C APIs differently.
- Select WMC server by UUID internally, display `AppName — ServerName`.

### P1 — frame conversion

The current path assumes exactly 1280×720 BGRA.

Implement a persistent Metal converter:

- input: arbitrary BGRA `MTLTexture`
- output: 1280×720 BGRA `CVPixelBuffer`
- default scaling: aspect-fit with black bars
- optional crop-fill
- no CPU readback
- use one command queue
- use `CVPixelBufferPool`
- use `CVMetalTextureCache`
- avoid `waitUntilCompleted()` if CMIO ownership can be safely chained; first prioritize correctness

Possible implementation:
- Metal render pipeline or MPSImageBilinear
- direct blit for exact-size frames

### P1 — timing

Replace frame-count PTS with host time.

Use:

```swift
let pts = CMClockGetTime(CMClockGetHostTimeClock())
```

The source stream must send a host-time nanosecond value consistent with its `.hostTime` clock.

### P1 — reconnect/state machine

Implement:

```text
idle
 ├─ activate-extension
 └─ ready
      ├─ producer-found -> streaming
      └─ producer-missing -> waiting
streaming
 ├─ producer-retired -> waiting
 ├─ sink-unavailable -> ready/error
 └─ stop -> ready
```

Observe Syphon announce/update/retire notifications.

### P1 — menu bar operation

After functionality is stable:

- switch WindowGroup to MenuBarExtra or add a menu bar controller
- `Start at login`
- auto-connect to last Syphon UUID
- bridge starts only after Camera Extension is installed
- no Dock icon if desired

### P2 — profiling

Compare:
- OBS + Syphon source + Virtual Camera
- Syphon Camera

Measure:
- app CPU %
- extension CPU %
- GPU time
- memory
- thermals
- end-to-end visual latency

Target is not an arbitrary zero; target is "bridge overhead is too small to matter next to WMC and Meet".

## Known risky points

### 1. Camera Extension template/API drift

Apple evolves the exact template. If generated code differs from this prototype, prefer the current Xcode Camera Extension template and transplant this project's source/sink logic.

### 2. Host → sink queue API

The CMIO C-level path is under-documented. Verify:
- queue retain/release
- callback signature
- stream identification
- `CMIODeviceStartStream`
- enqueue element ownership

### 3. Swift 6 concurrency

CMIO callback APIs may be `@Sendable`.
Do not blanket-disable strict concurrency. Isolate callbacks on explicit queues/actors where sensible.

### 4. Syphon callback thread

The frame callback can occur off the main thread. Never touch SwiftUI directly from it.

### 5. `waitUntilCompleted()`

It is safe for MVP but can serialize the GPU and increase latency.
After correctness:
- keep a small ring of output pixel buffers
- signal completion before enqueuing to CMIO, or use a completion handler
- never reuse a pixel buffer still owned downstream

## Files to treat as contracts

- `Shared/CameraConstants.swift`
- `Docs/DESIGN.md`
- `Docs/PERFORMANCE.md`
- `Docs/TEST_PLAN.md`

## Recommended first Codex prompt

> Open this repository on macOS. Treat Docs/CODEX_HANDOFF.md as the work order. First make the project compile with the current Xcode without changing the architecture. Do not work on Syphon yet. Use Test Pattern to make the Camera Extension appear in QuickTime and to verify host → CMIO sink → source stream. Run xcodebuild after each logical fix and record any deviations from the prototype in Docs/IMPLEMENTATION_NOTES.md.

## Recommended second Codex prompt

> Now integrate the current Syphon-Framework Metal client in the host app only. Preserve the Camera Extension dependency boundary. Confirm server discovery and `newFrameImage()` on the installed Syphon framework. Connect Webcam Motion Capture output to the existing CMSampleBuffer sink path. Keep 1280×720 BGRA exact-size only until live video appears.

## Recommended third Codex prompt

> Profile the bridge. Replace the exact-size-only Metal converter with a persistent GPU scaler only if Webcam Motion Capture output does not match 1280×720. Keep queue depth one and no CPU texture readback. Then compare process CPU/memory against OBS Virtual Camera and write the results to Docs/BENCHMARK.md.
