# Zero-copy audit

Status: optimization work in progress, 2026-08-11.

The current production path is a GPU conversion and is not zero-copy. For exact 1920x1080 BGRA input, the bridge now tries a one-time direct IOSurface probe, then a persistent Metal texture-cache plus blit path before using CI. A one-time runtime probe records the direct IOSurface contract stages without retrying the operation per frame.

## Boundary classification

| Boundary | Classification | Evidence / consequence |
| --- | --- | --- |
| WMC Syphon server -> `SyphonMetalClient` | reference only / IOSurface share, external-owned | `newFrameImage()` returns an `MTLTexture`; no CPU readback or pixel-plane memcpy in this project. Exact IOSurface ownership is external to the bridge. |
| `SyphonMetalClient` texture -> bridge | reference only | `LatestFrameStore` retains only the newest texture under a lock; no queue is accumulated. |
| bridge texture -> UniCamEx pixel buffer | GPU blit or GPU conversion | Exact `.bgra8Unorm` input uses `CVMetalTextureCache` plus one `MTLBlitCommandEncoder.copy`; other inputs use the CI compatibility path. Direct IOSurface enqueue/consumer validation is still disabled. |
| pixel buffer -> `CMSampleBuffer` | reference only | `CMSampleBufferCreateReadyWithImageBuffer` wraps the image buffer and format description; it does not copy pixel planes. |
| sample buffer -> UniCamEx sink queue | reference only / external-owned | `Unmanaged.passRetained` transfers the sample-buffer reference to the CoreMediaIO queue. UniCamEx consumes it asynchronously. |
| UniCamEx -> visible camera feed | unknown / external-owned | Implemented by the signed UniCamEx system extension; verified visually in QuickTime and Meet. |

## Queue and allocation audit

- Effective queue depth: 1 at the bridge sender. The `shouldEnqueue` gate waits for UniCamEx's altered callback and drops intermediate ticks.
- Stale-frame policy: newest texture replaces the previous texture in `LatestFrameStore`; no unbounded frame list exists.
- CPU readback: none in the steady state.
- CPU pixel-plane memcpy: none in the steady state.
- Per-frame `CIContext`: removed; one context is created during `UniCamExSender` initialization.
- Pixel-buffer allocation: `CVPixelBufferPool` with a minimum warm-up count of 3 is used. The pool may allocate during warm-up or pressure, but the bridge does not call `CVPixelBufferCreate` per frame.
- Sample-buffer allocation: CoreMedia creates a wrapper per submitted frame. This is an API-owned object and cannot be eliminated with the current sink-stream contract.
- Remaining GPU work: one Metal blit for exact `.bgra8Unorm` input, or one CI render for the compatibility path. Direct IOSurface wrapping is probed once but is not used until asynchronous sink/lifetime validation exists.

## Verification

- Xcode Debug build succeeds after the pool/context change.
- WMC server discovered as `Webcam Motion Receiver/Webcam Motion Receiver`.
- WMC character frames observed through UniCamEx in QuickTime.
- Phase 0 test pattern and Syphon-disconnected fallback both remain functional.
- Initial instrumented WMC run: 8 one-second samples showed approximately 116.2-118.6% CPU and 106,704-107,616 KB RSS. A stack sample identified continuous diagnostic-frame generation as the dominant avoidable cost.
- After fixing fallback scheduling so the diagnostic generator runs only when no valid Syphon client exists: 4 one-second samples showed approximately 16.5-18.8% CPU and stable 97,312 KB RSS while WMC frames remained visible through UniCamEx.
- Queue-pressure run: after 300 accepted frames at 30 fps, the sender reported `enqueued=300 dropped=0`, confirming no queue-pressure drops in the observed ~10-second interval. Average Syphon-publication-to-bridge-dispatch latency was 8.66 ms; process samples during the run were 17.9-18.9% CPU and 99,952 KB RSS.
- `mactop` headless CSV run (5 samples at 1 s): Bridge CPU settled at 16.8-17.5%, RSS 100,112-100,128 KB, and process GPU time was 18.0-22.4 ms/s. System GPU active was about 49-50%; thermal state remained normal. The first sample was a warm-up sample and reported 0% for the process.
- OBS comparison with the existing Syphon Client scene and virtual camera enabled: OBS 32.2.1 main process measured 21.9-23.2% CPU, 89.1-89.4 ms/s GPU time, and 286,752 KB RSS. The paired Bridge sample measured 16.2% CPU, 19.4 ms/s GPU time, and 102,080 KB RSS. OBS helper processes and its camera system extension were excluded from the main-process figures.
- Signpost points are present for `SyphonFrameReceived`, `CITextureRender`, and `UniCamExEnqueue`; inspect them with Instruments' Points of Interest / os_signpost view during a longer capture.

## Open work

1. Measure WMC input dimensions/fps, CPU, memory, and end-to-end latency under sustained Meet use.
2. Determine whether WMC's Syphon texture and UniCamEx's sink buffer can share the same IOSurface without the CI render.
3. Add `os_signpost` timing around Syphon receipt, CI render, queue enqueue, and sink consumption.
4. Recheck pool pressure and effective queue depth under dropped-frame conditions.

The direct IOSurface wrap probe is not part of the steady-state path: it runs once after the first compatible texture and never retries per frame.

## 2026-08-11 probe and routing update

- Exact 1920x1080 input: `CIImage` is rendered directly; no scale, fit, letterbox, or translation calculation is performed.
- Non-exact input: existing scale-and-center compatibility behavior is retained.
- Runtime report includes texture dimensions, Metal pixel format/storage/usage, IOSurface presence, IOSurface dimensions/stride/element size/allocation/pixel format/plane count/seed, and equivalent pooled-buffer properties.
- The selected path is explicitly logged once as `METAL_BLIT` or `CORE_IMAGE_FALLBACK`; `METAL_BLIT` means one GPU copy, not zero-copy.
- Live WMC verification selected `METAL_BLIT`: 3900 blits, 0 CI renders, 1 sink-pressure drop over the sustained run. The direct IOSurface probe stopped at stage 2 with `-6661 invalid-argument`; stages 3-7 remain intentionally unattempted, so direct sharing is not claimed.
- The exact-size Metal blit path is now the production route for compatible WMC textures; CI remains the compatibility fallback.

## Baseline interpretation

The original high CPU level was not caused only by CI render: the fallback diagnostic generator was running concurrently with the live Syphon client. That was fixed and verified. The remaining ~17-19% CPU includes the required CI render and external sink path. The probe now records the exact wrap/format/sample stages on the current runtime; until enqueue and consumer validation also pass, the GPU conversion remains the justified production implementation.
