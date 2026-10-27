# Codex work order: UniCamEx-first architecture

Historical work order for the UniCamEx bridge. The restrictions below apply to
that earlier route, not to the separate NativeCamera backend added on 2026-10-27.
For its current 1080p/30 default, optional 720p/30 output, and measured limits,
see [Native Camera operation](NATIVE_CAMERA_30FPS.md) and the
[current audit](ZERO_COPY_AUDIT.md).

## Goal

Build a tiny macOS bridge that sends frames to the installed **UniCamEx** virtual camera so that Google Meet / Chrome can use Webcam Motion Capture output without running OBS.

Target path:

```text
Phase 0:
TestPattern -> bridge app -> UniCamEx virtual camera -> QuickTime / Chrome / Meet

Phase 1:
Webcam Motion Capture -> Syphon -> bridge app -> UniCamEx virtual camera -> Chrome / Meet

Phase 2:
Optimize the hot path toward zero-copy / minimum-copy.
```

## Primary rule

Treat **UniCamEx** as the production virtual-camera backend.

- Do not start by building our own Camera Extension.
- Do not start with DAL.
- Do not start with OBS integration.
- Build only a normal macOS app/library that feeds frames into UniCamEx.

## Upstreams to inspect on the target Mac

- UniCamEx repository and releases
- Its public API for sending textures/frames
- Its source/sink-stream path if direct API linkage is insufficient
- Syphon framework / SyphonMetalClient API

## Architecture

Preferred final shape:

```text
WMC
  |
  v
Syphon receiver
  |
  v
MTLTexture / IOSurface
  |
  v
UniCamEx adapter
  |
  v
Installed UniCamEx virtual camera
  |
  v
Chrome / Google Meet
```

## Phase 0 acceptance criteria

Do not touch Syphon until ALL of these are true:

1. UniCamEx is installed from a signed release or otherwise available on the target Mac.
2. The system exposes the `UniCamEx` camera in at least one diagnostic client.
3. The bridge app builds on the target Mac with current Xcode.
4. The bridge app can generate a moving test pattern.
5. The bridge app can feed that moving test pattern into UniCamEx.
6. QuickTime Player (or similar) displays the moving test pattern through the UniCamEx camera.
7. Chrome enumerates the UniCamEx camera.
8. Google Meet can select UniCamEx and display the moving test pattern.
9. No paid Apple Developer Program credential is required for normal use of this path.
10. Runtime steps are documented in `Docs/RUNTIME_NOTES.md`.

If this fails because the installed UniCamEx API surface differs from assumptions in this handoff, adapt the bridge to the actual upstream API. Do not abandon the architecture prematurely.

## Phase 1 acceptance criteria

After Phase 0 passes:

1. Discover the `Webcam Motion Receiver` Syphon server (or whichever server WMC exposes).
2. Receive frames using the modern Metal path if available.
3. Default output format: 1280x720 @ 30 fps.
4. Send frames into UniCamEx without introducing an unbounded queue.
5. If Syphon disappears, fall back to a deterministic diagnostic frame rather than hanging.
6. Old frames must be dropped; newest frame wins.
7. Measure CPU, latency, and memory before optimization.
8. Record assumptions and deviations in `Docs/RUNTIME_NOTES.md`.

## Phase 2 acceptance criteria (performance / zero-copy)

Create `Docs/ZERO_COPY_AUDIT.md`.

For every boundary, classify it as one of:

- reference only
- IOSurface share
- GPU conversion / GPU blit
- CPU memcpy
- unknown / owned by external component

Optimization goals:

1. Never read a texture back to CPU in the steady-state hot path.
2. No per-frame malloc after warm-up.
3. No CPU memcpy of pixel planes after warm-up.
4. Avoid extra render targets unless pixel-format conversion is mandatory.
5. Keep effective queue depth at 1.
6. Prefer same-IOSurface wrapping when technically possible.
7. Add timing instrumentation (`os_signpost` or equivalent).
8. Document every unavoidable copy explicitly.

The task is **not** complete merely because it works. The task is complete when every copy is found and justified.

## Suggested implementation order

### Step A: environment confirmation

- Verify installed macOS version
- Verify Xcode version
- Install UniCamEx release
- Verify camera appears in QuickTime or another client

### Step B: minimal bridge with test pattern

- Start from the skeleton in `BridgeApp/`
- Implement a minimal app that generates a moving test pattern
- Implement `UniCamExSender` using the actual upstream API on this Mac
- Verify video through the `UniCamEx` camera

### Step C: Syphon input

- Implement `SyphonFrameSource`
- Swap the source from test pattern to Syphon
- Keep fallback test pattern available by flag or UI toggle

### Step D: performance work

- Audit copies
- Convert to same-IOSurface / direct texture transfer where possible
- Add instrumentation and document results

## First prompt for Codex

Use this verbatim first:

> Read `Docs/CODEX_HANDOFF.md` and treat it as the work order. Perform Phase 0 only. Do not work on Syphon yet. Inspect the actual installed or cloned UniCamEx upstream API on this Mac and wire the provided bridge skeleton so that a moving test pattern is visible via the `UniCamEx` camera in QuickTime and Chrome. Record every build/runtime deviation in `Docs/RUNTIME_NOTES.md`.

## Second prompt for Codex

Use this after Phase 0 passes:

> Phase 0 passed. Now implement Phase 1. Add Syphon input from Webcam Motion Capture while preserving the fallback test pattern path. Default to 1280x720 @ 30 fps, newest-frame-wins, no unbounded queue, and document all assumptions in `Docs/RUNTIME_NOTES.md`.

## Third prompt for Codex

Use this after Syphon works:

> Optimize the Syphon -> UniCamEx hot path for zero-copy or minimum-copy. Create `Docs/ZERO_COPY_AUDIT.md`. The task is not complete because it works; the task is complete only when every remaining copy is identified and justified.
