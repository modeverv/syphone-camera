# Syphon Camera

A minimal macOS virtual camera bridge designed for **Webcam Motion Capture / Syphon → Google Meet, Zoom, Teams, etc.**

The project intentionally does not contain a scene graph, encoder, recorder, audio path, or compositor. Its job is only:

```text
Webcam Motion Capture
        │
        │ Syphon / Metal texture
        ▼
SyphonCameraApp
        │
        │ Metal blit to CVPixelBuffer
        ▼
CoreMediaIO sink stream
        │
        ▼
SyphonCameraExtension
        │
        │ CMIO source stream
        ▼
Meet / Zoom / Teams
```

Default output: **1280×720 @ 30 fps, BGRA**, queue depth 1.

## Status

This repository is an implementation-oriented prototype and Codex handoff package.

The code follows Apple's modern CoreMediaIO Camera Extension architecture (macOS 12.3+) and the current Syphon Metal client API. It is intentionally structured so the app can compile and run in **test-pattern mode without Syphon**, then Syphon can be attached as an optional framework.

This package was generated outside macOS/Xcode, so the final Xcode build/signing pass must be performed on a Mac. The most likely adjustments are signing identifiers, exact Xcode/Swift API spelling, and Syphon framework integration.

## Requirements

- macOS 13+ recommended
- Xcode 16+ recommended
- Paid Apple Developer signing identity for a practical Camera Extension workflow
- `xcodegen` (`brew install xcodegen`)
- Syphon framework when enabling real Syphon input

## First build

1. Edit `project.yml`:
   - replace `DEVELOPMENT_TEAM: YOURTEAMID`
   - replace bundle IDs if desired
   - keep app + extension App Group identical
2. Generate the project:

   ```bash
   xcodegen generate
   open SyphonCamera.xcodeproj
   ```

3. Build `SyphonCameraApp`.
4. Copy/build the app into `/Applications/SyphonCamera.app`.
5. Launch it and click **Activate Camera Extension**.
6. Approve the system extension in System Settings if macOS asks.
7. Open QuickTime/Meet and choose **Syphon Camera**.
8. Start in **Test Pattern** mode first.
9. Add `Syphon.framework` to the host app target, then switch source to **Syphon**.

## Why a sink stream?

The Camera Extension is a sandboxed system extension. The host application owns Syphon and Metal ingestion; it pushes CMSampleBuffers into a CMIO **sink stream**. The extension consumes those buffers and immediately forwards them through a CMIO **source stream** exposed as the camera.

This keeps Syphon out of the system extension and isolates all third-party code in the ordinary app process.

## Project layout

```text
Shared/
  CameraConstants.swift       IDs, defaults, pixel format
  SampleBufferFactory.swift   CVPixelBuffer -> CMSampleBuffer
  MetalFrameConverter.swift   MTLTexture -> CVPixelBuffer
SyphonCameraApp/
  SyphonCameraApp.swift       SwiftUI entry
  ContentView.swift           tiny control UI
  AppModel.swift              orchestration
  CameraExtensionManager.swift
  CMIOSinkWriter.swift        host -> extension sink queue
  SyphonFrameSource.swift     optional Syphon receiver
  TestPatternSource.swift     build/debug without Syphon
SyphonCameraExtension/
  main.swift
  CameraProviderSource.swift
  CameraDeviceSource.swift
  SourceStreamSource.swift
  SinkStreamSource.swift
Docs/
  DESIGN.md
  CODEX_HANDOFF.md
  BUILD_AND_SIGNING.md
  PERFORMANCE.md
  TEST_PLAN.md
```

## Performance design

- no CPU readback from `MTLTexture`
- no H.264/VP8/AV1 encode in this app
- no render scene graph
- no frame queue growth
- one Metal blit per delivered frame
- one CVPixelBuffer pool
- latest-frame-wins at the source
- default 720p30

Google Meet performs its own encode; this program only publishes an uncompressed camera stream.

## Syphon integration

`SyphonFrameSource.swift` is guarded by:

```swift
#if canImport(Syphon)
```

Without the framework, the app still builds and test-pattern mode works.

With a current Syphon framework added to the host app target, the receiver uses:

- `SyphonServerDirectory.shared().servers`
- `SyphonMetalClient`
- `newFrameImage() -> MTLTexture`

Select the WMC server by its Syphon server name or application name.

## CLI/headless follow-up

The MVP uses a tiny menu/UI app because Camera Extension activation is inherently app/system-extension oriented. After the first install, the ingest loop can be moved to a login item or launch agent while retaining the signed host bundle.

See `Docs/CODEX_HANDOFF.md`.
