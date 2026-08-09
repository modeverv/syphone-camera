# Design

## Problem statement

OBS is overkill for the use case:

```text
Webcam Motion Capture output -> virtual camera -> Meet
```

We do not need scene graphs, preview rendering, browser sources, audio mixing, or streaming features.

## Chosen architecture

Use **UniCamEx** as the virtual-camera backend and implement only a tiny producer bridge.

```text
WMC -> Syphon -> bridge app -> UniCamEx -> Meet
```

## Why UniCamEx

- It is already designed around CoreMediaIO Camera Extension on supported macOS.
- It can be installed independently of this project.
- It avoids building/signing our own extension in the first iteration.
- It appears to expose a direct texture/frame sending path that is a strong fit for this project.

## Components

### 1. FrameSource
Abstraction for the video producer.

Implementations:
- `TestPatternFrameSource`
- `SyphonFrameSource`

Output contract:
- ideally `MTLTexture`
- optionally `CVPixelBuffer` or `CMSampleBuffer` if upstream API demands it

### 2. UniCamExSender
Adapter that sends frames into UniCamEx.

Possible strategies, in preferred order:
1. direct public texture-send API from UniCamEx
2. direct frame / sample-buffer send API from UniCamEx
3. sink-stream producer path if public API linkage is insufficient

### 3. BridgeEngine
Pulls frames from the active `FrameSource` and forwards them to `UniCamExSender`.

Rules:
- newest frame wins
- small or zero queue
- deterministic fallback frame if producer unavailable
- no UI dependence in the hot path

## Performance model

### MVP
Likely acceptable:
- 1 GPU conversion/blit if needed
- no CPU readback
- no per-frame heap churn after warm-up

### Target
Best case:
- Syphon texture backed by IOSurface
- direct texture or same-surface handoff to UniCamEx path
- no CPU memcpy
- no extra render target if formats already match

## Fallbacks

If UniCamEx direct API linkage is brittle on the target Mac:
- inspect and use the actual sink-stream implementation from upstream
- keep the architecture, do not revert immediately to DAL or self-built extension
