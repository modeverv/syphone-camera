# Design

## 1. Goal

Provide the smallest practical bridge from a Syphon producer to a macOS virtual camera.

Non-goals:

- recording
- audio mixing
- scene composition
- chroma key
- browser source
- encoding
- streaming to a server
- filters

## 2. Architecture

```text
                   ordinary app process
┌───────────────────────────────────────────────────────────────┐
│ SyphonServerDirectory                                         │
│        │                                                      │
│ SyphonMetalClient                                             │
│        │ MTLTexture                                           │
│        ▼                                                      │
│ MetalFrameConverter                                           │
│        │ CVPixelBuffer (IOSurface-backed, Metal compatible)   │
│        ▼                                                      │
│ SampleBufferFactory                                           │
│        │ CMSampleBuffer                                       │
│        ▼                                                      │
│ CMIOSinkWriter ── CMSimpleQueue ───────────────────────┐      │
└────────────────────────────────────────────────────────┼──────┘
                                                         │
                                      CoreMediaIO boundary│
                                                         ▼
┌──────────────────── Camera System Extension ──────────────────┐
│ CMIO sink stream                                              │
│        │ consumeSampleBuffer                                  │
│        ▼                                                      │
│ CameraDeviceSource                                            │
│        │ send                                                 │
│        ▼                                                      │
│ CMIO source stream                                            │
└───────────────────────────────────────────────────────────────┘
                                                         │
                                                         ▼
                                                Meet / Zoom / etc
```

## 3. Frame lifecycle

1. Syphon invokes a new-frame callback.
2. `newFrameImage()` yields an `MTLTexture`.
3. A Metal-compatible `CVPixelBuffer` is acquired from a pool.
4. One Metal blit copies the source texture into the pixel-buffer texture.
5. `CMSampleBuffer` wraps the `CVPixelBuffer`.
6. The host enqueues it to the CMIO sink queue.
7. The extension consumes it.
8. The extension forwards that same `CMSampleBuffer` to source-stream clients.

No video encoder exists in the bridge.

## 4. Latency policy

The application must never queue old video.

Rules:

- CMIO sink queue size = 1
- if full: drop incoming frame
- do not retry a dropped frame
- do not buffer Syphon callbacks
- target 30 fps
- keep one `CVPixelBufferPool`

This explicitly chooses smooth low latency over perfect frame delivery.

## 5. Process boundary

Syphon runs in the host app, not the Camera Extension.

Reasons:

- system extension is sandboxed
- third-party framework behavior stays outside the privileged/special extension
- debugging is simpler
- Syphon reconnect does not restart camera registration
- Camera Extension remains dependency-minimal

## 6. Formats

MVP:

- 1280×720
- 30 fps
- `kCVPixelFormatType_32BGRA`
- `MTLPixelFormat.bgra8Unorm`

WMC/Syphon must currently produce exactly 1280×720 BGRA8 for the GPU blit path.

Phase 2 can add:

- arbitrary input resolution
- Metal Performance Shaders scaling
- crop/letterbox modes
- NV12 source stream if a measurable benefit exists

Do not add conversion merely because NV12 looks more "video-ish"; benchmark Meet first.

## 7. Timing

The bridge currently uses monotonic frame-count PTS for incoming Syphon frames.

Preferred final behavior:

- timestamp each accepted Syphon frame using `CMClockGetHostTimeClock()`
- construct `CMSampleBuffer` PTS from host clock
- report matching `hostTimeInNanoseconds` from the extension

Codex should normalize this once the first live end-to-end frame works.

## 8. Failure behavior

- Syphon server absent: show error, do not crash extension
- Syphon disappears: stop host ingestion, leave camera installed
- Meet starts before producer: extension may show last frame; phase 2 should add black/test fallback
- sink queue full: drop
- incompatible texture size/format: drop + throttled warning
- extension deactivated: host reports virtual camera unavailable

## 9. Security

No network listener.
No microphone access.
No file persistence of video.
No browser embedding.
No analytics.

Camera content remains local until the conferencing app reads the camera and performs its own transport.
