# Codex Work Order: Syphon → UniCamEx Bridge Further Optimization

Historical optimization work order for the UniCamEx bridge. Its instruction not
to implement a Camera Extension describes that earlier task; it does not apply
to the separate NativeCamera backend added on 2026-10-27. Current implementation
and verification are recorded in [the audit](ZERO_COPY_AUDIT.md) and
[Native Camera operation](NATIVE_CAMERA_30FPS.md).

Repository: https://github.com/modeverv/syphone-camera

## 1. Goal

Optimize the existing same-Mac video path used for:

Webcam Motion Capture (WMC) → Syphon → syphone-camera → UniCamEx → Chrome / Google Meet

The current implementation is already functional and avoids CPU pixel readback / CPU pixel-plane memcpy in the steady-state path. The remaining hot-path image work is one GPU-side `CIContext.render()` into a new IOSurface-backed 1920x1080 BGRA `CVPixelBuffer`.

WMC is known to output a fixed **1920x1080** Syphon stream in the intended production configuration. UniCamEx v1.2.0 also exposes a fixed **1920x1080 BGRA** sink stream.

The purpose of this task is therefore to determine whether the remaining conversion/copy can be removed or reduced.

Priority order:

1. Attempt true direct IOSurface / CVPixelBuffer handoff with no image copy.
2. If direct sharing is not viable, replace Core Image rendering with the smallest possible Metal-only copy/blit path.
3. Preserve the current Core Image path only as a compatibility fallback if necessary.
4. Measure before/after performance and retain only changes that are correct and demonstrably useful.

Do not replace UniCamEx or implement a new Camera Extension. The existing signed UniCamEx installation must continue to be used so that this project does not require the developer to build or sign a Camera Extension.

---

## 2. Current Known Architecture

Current steady-state path:

```text
WMC
  ↓
Syphon server
  ↓
SyphonMetalClient
  ↓ reference / IOSurface-backed MTLTexture
LatestFrameStore
  ↓ reference only, newest-frame-wins
UniCamExSender.send(texture:)
  ↓
CIImage(mtlTexture:)
  ↓
CIContext.render()
  ↓ GPU render into a pooled IOSurface-backed 1920x1080 BGRA CVPixelBuffer
  ↓
CMSampleBuffer
  ↓ reference
CoreMediaIO UniCamEx sink queue
  ↓
signed UniCamEx Camera Extension
  ↓
Chrome / Google Meet
```

Relevant current code:

- `BridgeApp/Sources/UniCamExSender.swift`
- `Docs/ZERO_COPY_AUDIT.md`
- `Docs/PERFORMANCE.md`
- `Docs/DESIGN.md`
- instrumentation helpers already present in the repository

Current `UniCamExSender` creates a `CVPixelBufferPool` with:

- width: 1920
- height: 1080
- pixel format: `kCVPixelFormatType_32BGRA`
- IOSurface backing
- minimum pool size: 3

and performs:

```swift
let image = CIImage(mtlTexture: texture, ...)
...
ciContext.render(fitted, to: pixelBuffer, ...)
```

The current code already avoids:

- CPU readback of Syphon textures
- `getBytes`-style CPU pixel extraction
- CPU pixel-plane memcpy
- unbounded frame queues
- creating a `CIContext` every frame

Do not regress any of these properties.

---

## 3. Important New Assumption

For the intended WMC use case, treat the WMC Syphon source as fixed:

```text
1920 x 1080
30 fps currently expected in ordinary use
```

The implementation must verify the actual incoming texture properties at runtime rather than blindly trusting this assumption.

When the input is exactly compatible with the UniCamEx output format, do not perform scaling, fitting, letterboxing, or other geometric processing.

The current generic scale/translate Core Image path exists because arbitrary input sizes were previously allowed. The production WMC path no longer needs this overhead when dimensions match exactly.

Retain a safe compatibility path for non-1920x1080 sources if practical, but optimize the exact 1920x1080 WMC case first.

---

# Phase A — Establish Exact Surface Compatibility

Before changing the hot path, add a diagnostic facility that compares the Syphon IOSurface with a known-good UniCamEx-compatible pooled CVPixelBuffer.

For the incoming `MTLTexture`, log once per source change:

```text
MTLTexture.width
MTLTexture.height
MTLTexture.pixelFormat
MTLTexture.storageMode
MTLTexture.usage
whether texture.iosurface is non-nil
```

For the underlying Syphon IOSurface, log:

```text
IOSurfaceGetWidth
IOSurfaceGetHeight
IOSurfaceGetBytesPerRow
IOSurfaceGetBytesPerElement
IOSurfaceGetAllocSize
IOSurfaceGetPixelFormat
IOSurfaceGetPlaneCount
IOSurfaceGetSeed
```

Where meaningful, inspect related IOSurface properties/dictionary values without dumping excessive per-frame logs.

Create one buffer from the current known-good `CVPixelBufferPool` and log the equivalent:

```text
CVPixelBufferGetWidth
CVPixelBufferGetHeight
CVPixelBufferGetPixelFormatType
CVPixelBufferGetBytesPerRow
CVPixelBufferIsPlanar
CVPixelBufferGetPlaneCount
CVPixelBufferGetIOSurface
```

For its IOSurface, log the same IOSurface properties.

Produce a concise side-by-side compatibility report such as:

```text
Property                  Syphon                 UniCamEx pool
----------------------------------------------------------------
width                     1920                   1920
height                    1080                   1080
pixel format              BGRA8Unorm / ????      32BGRA
IOSurface pixel format    ...
bytesPerRow               ...
planeCount                ...
allocSize                 ...
```

Do not infer compatibility solely from width and height.

Document the results in `Docs/ZERO_COPY_AUDIT.md`.

---

# Phase B — Re-investigate Direct IOSurface Wrapping

A previous `CVPixelBufferCreateWithIOSurface` experiment failed at runtime. Re-investigate it, but do so as a controlled startup/source-change probe rather than attempting a known-bad operation on every frame.

Goal:

```text
Syphon IOSurface
       ↓ same backing storage
CVPixelBuffer
       ↓ wrapper
CMSampleBuffer
       ↓
UniCamEx sink queue
```

No Core Image render.
No Metal blit.
No CPU pixel copy.
No allocation of a second full-frame image surface for each accepted frame.

## Required investigation

Determine precisely where the previous direct path fails.

Distinguish at least these stages:

1. retrieving the IOSurface from the Syphon `MTLTexture`
2. creating/wrapping a `CVPixelBuffer` using the IOSurface
3. creating a compatible `CMVideoFormatDescription`
4. creating a `CMSampleBuffer`
5. enqueueing into the UniCamEx sink queue
6. UniCamEx consuming the buffer
7. UniCamEx source camera producing a visible frame in QuickTime / Chrome / Meet

Record the exact OSStatus / CVReturn / CoreMedia error codes and translate them to readable diagnostics where possible.

Do not report merely "direct IOSurface wrapping failed."

We need to know exactly **which contract is violated**.

## Direct-path eligibility

Use the direct path only if all relevant properties are compatible.

At minimum verify:

- 1920x1080
- compatible BGRA byte ordering / Metal pixel format
- IOSurface exists
- non-planar layout as expected
- acceptable bytes-per-row / layout
- `CVPixelBufferCreateWithIOSurface` succeeds
- sample-buffer format description matches the UniCamEx sink stream contract
- real WMC motion is visible correctly through UniCamEx
- colors are correct
- orientation is correct
- no persistent stale-frame or lifetime corruption occurs

Pay special attention to ownership and lifetime.

Syphon owns the source surface. A frame must remain alive for as long as UniCamEx / CoreMediaIO may consume the sample buffer. Do not create a use-after-free by dropping the `MTLTexture`, Syphon image, IOSurface, CVPixelBuffer, or CMSampleBuffer too early.

If an explicit attachment/reference is needed to keep the underlying surface alive, implement it safely.

Do not copy pixels merely to make lifetime management easier unless the direct path is proven unsafe or incompatible.

---

# Phase C — If Direct Sharing Works

If direct IOSurface wrapping is fully functional:

Make it the preferred fast path for compatible WMC frames.

Desired production path:

```text
WMC
 ↓
Syphon / IOSurface
 ↓ reference
MTLTexture
 ↓ same IOSurface
CVPixelBuffer
 ↓ reference
CMSampleBuffer
 ↓ reference
UniCamEx sink queue
 ↓
Meet
```

Expected full-frame image operations performed by `syphone-camera`:

```text
CPU full-frame copies: 0
GPU full-frame copies/renders: 0
```

The bridge should perform only metadata/reference/lifetime/scheduling work for each compatible frame.

Keep the newest-frame-wins behavior and effective sender queue depth of 1.

Add a visible runtime/log indication such as:

```text
Video path: DIRECT_IOSURFACE
```

Do not log this every frame.

---

# Phase D — Metal-only Fallback

If the direct IOSurface path is impossible or unreliable, replace the current Core Image conversion for the exact-size WMC case with a minimal Metal path.

Target:

```text
Syphon MTLTexture
      ↓
MTLBlitCommandEncoder.copy(...)
      ↓
MTLTexture backed by pooled UniCamEx CVPixelBuffer
      ↓
CMSampleBuffer
      ↓
UniCamEx
```

Use `CVMetalTextureCache` to expose the destination `CVPixelBuffer` as a Metal texture.

Prefer:

- one persistent `MTLDevice`
- one persistent command queue
- one persistent `CVMetalTextureCache`
- the existing warmed `CVPixelBufferPool`
- no per-frame CIContext
- no per-frame Core Image graph creation
- no shader if a pure texture blit is valid
- no scaling for 1920x1080 → 1920x1080
- no color-space transform unless proven necessary

If source and destination texture formats prevent a raw Metal blit, use the smallest possible Metal render/compute conversion and document why it is needed.

Do not silently introduce a CPU fallback.

For exact-compatible WMC input, preferred fallback order is:

```text
1. direct IOSurface
2. Metal blit
3. minimal Metal shader/conversion
4. existing Core Image render
```

Core Image remains last-resort compatibility behavior, not the preferred WMC path.

Add a one-time runtime indication:

```text
Video path: METAL_BLIT
```

or:

```text
Video path: CORE_IMAGE_FALLBACK
```

---

# Phase E — Remove Unnecessary Exact-Size Work

When the input texture is exactly 1920x1080:

Do not execute the existing:

```swift
scale = min(...)
CGAffineTransform(scaleX:y:)
translation calculation
CIImage transformed(...)
```

For a compatible direct or Metal-blit path there should be no geometric transformation.

If orientation correction is actually required by WMC/Syphon, determine where it originates.

Do not retain a full Core Image render solely for vertical flipping without proving that flipping is necessary.

If flipping is required:

1. determine whether Syphon texture coordinates / source orientation semantics can resolve it without copying
2. otherwise handle it in a minimal Metal pass
3. document the reason

Verify visually with a deliberately asymmetric test image containing:

```text
TOP
BOTTOM
LEFT
RIGHT
```

plus distinct corner markers.

---

# Phase F — Keep Generic Compatibility

Do not break the test-pattern path or arbitrary Syphon sources unnecessarily.

Suggested policy:

```text
if exact direct-compatible 1920x1080 WMC-like texture:
    DIRECT_IOSURFACE
else if exact 1920x1080 and Metal-copy-compatible:
    METAL_BLIT
else:
    existing/general conversion path
```

The exact routing may differ if runtime evidence shows a better approach.

Do not optimize based only on Syphon server name. Prefer actual texture/surface capability checks.

---

# Phase G — Performance Measurement

Before implementation changes, capture a reproducible baseline from the current master branch.

Then measure each viable implementation under the same conditions.

Primary real workload:

```text
Webcam Motion Capture
  -> Syphon
  -> syphone-camera
  -> UniCamEx
  -> Google Meet or a stable camera consumer
```

Use at least a sustained 60-second run after warm-up.

Record:

- bridge CPU %
- bridge RSS
- bridge GPU time if available
- effective fps
- frames received
- frames enqueued
- frames dropped due to sink backpressure
- effective queue depth
- Syphon publication → bridge enqueue latency
- time spent in conversion/copy step
- thermal state if practical

Use the existing `os_signpost` / instrumentation infrastructure and extend it as needed.

Relevant signposts should clearly distinguish:

```text
SyphonFrameReceived
DirectIOSurfaceWrap
MetalBlit
CITextureRender
UniCamExEnqueue
```

Only the path actually used should appear continuously.

Update `Docs/PERFORMANCE.md` and `Docs/ZERO_COPY_AUDIT.md` with:

- hardware
- macOS version
- Xcode version
- UniCamEx version
- source
- resolution/fps
- measurement commands/tools
- before/after values
- interpretation

Do not claim improvement from a single short sample.

---

# Phase H — Correctness / Regression Tests

All of the following must remain functional:

1. project builds with the existing unsigned local build procedure
2. no custom Camera Extension is introduced
3. separately installed signed UniCamEx remains the camera backend
4. WMC Syphon server is discovered
5. WMC 1920x1080 moving image appears through UniCamEx
6. QuickTime preview works
7. Chrome / Google Meet sees UniCamEx and receives moving video
8. diagnostic fallback still works when the Syphon source disappears
9. reconnecting/restarting WMC does not permanently break the bridge
10. queue remains bounded / newest-frame-wins
11. no growing memory usage during sustained operation
12. no CPU pixel readback in the WMC hot path
13. no CPU pixel memcpy in the WMC hot path
14. no obvious color-channel swap
15. no vertical/horizontal inversion
16. no stale or torn frames caused by incorrect IOSurface lifetime

Run a sustained test long enough to catch asynchronous lifetime errors.

---

# Phase I — Explicit Non-goals

Do NOT:

- create a new CoreMediaIO Camera Extension
- require paid Apple Developer Program membership for this bridge
- replace the already installed signed UniCamEx extension
- add OBS to the video path
- add CPU pixel readback
- use `MTLTexture.getBytes`
- allocate a full 1920x1080 intermediate byte array per frame
- introduce an unbounded frame queue
- change the network H.264 sender/receiver unless needed to keep the build working
- optimize the unrelated network transport as part of this task
- rewrite the project in Rust
- make speculative large architectural changes outside this hot path

Keep this change focused on same-Mac Syphon → UniCamEx frame transfer.

---

# Phase J — Failure Policy

Optimization is subordinate to correctness.

If direct IOSurface sharing fails:

1. identify the exact failure point
2. record actual error/status values
3. explain the likely API/layout/lifetime incompatibility
4. do not retry the failed direct conversion on every frame
5. fall back automatically to the next best supported path

If Metal blit is not measurably better than the existing CI path, keep the implementation only if it materially simplifies the architecture without regressions. Otherwise retain the better measured implementation.

Do not force "zero-copy" terminology when the implementation still performs a GPU copy.

Use precise labels:

- `reference-only / direct IOSurface`
- `GPU blit`
- `GPU render/conversion`
- `CPU copy`
- `external-owned / unknown`

---

# Phase K — Deliverables

Commit the implementation together with documentation.

Expected changed/new artifacts:

```text
BridgeApp/Sources/UniCamExSender.swift
possibly one or more small Metal/CV helper files
Docs/ZERO_COPY_AUDIT.md
Docs/PERFORMANCE.md
possibly Docs/DIRECT_IOSURFACE_PROBE.md
tests or diagnostic utilities where useful
```

Keep source files reasonably small. If direct-IOSurface diagnostics or Metal conversion become substantial, factor them out of `UniCamExSender.swift`.

At completion provide a concise report containing:

1. selected production path
2. whether true zero-copy was achieved
3. if not, exact reason direct sharing failed
4. number/type of full-frame image operations per accepted frame
5. CPU/GPU/RSS before and after
6. latency before and after
7. correctness tests performed
8. known remaining limitations

---

# Definition of Done

The task is complete when one of these outcomes is demonstrated.

## Preferred outcome A — True direct sharing

```text
Syphon IOSurface
→ CVPixelBuffer
→ CMSampleBuffer
→ UniCamEx
```

with:

```text
CPU full-frame copy = 0
GPU full-frame copy/render = 0
```

and stable WMC → Meet operation.

## Acceptable outcome B — Minimal GPU blit

```text
Syphon MTLTexture
→ Metal blit
→ IOSurface-backed CVPixelBuffer
→ CMSampleBuffer
→ UniCamEx
```

with:

```text
CPU full-frame copy = 0
GPU full-frame copy = 1
Core Image hot-path work = 0
```

and measured performance at least as good as the existing implementation.

## Acceptable outcome C — Existing CI path retained with proof

If neither A nor B can be made correct or beneficial, retain the current CI path but provide:

- exact evidence why direct IOSurface sharing fails
- exact evidence why Metal blit cannot replace CI or does not improve performance
- complete measurements
- no regression

The result must be evidence-driven rather than assuming that "zero-copy" is automatically faster.

---

## Additional Engineering Principle

WMC already renders the final 1920x1080 image. The bridge should ideally not perform image processing at all.

For the normal WMC → Meet workload, treat the bridge as a **surface/reference transport mechanism**, not an image compositor.

The ideal steady-state CPU responsibility is limited to:

```text
frame availability
reference ownership/lifetime
timestamp/sample-buffer metadata
CoreMediaIO sink backpressure
queue scheduling
```

Pixel manipulation should occur only when an API compatibility constraint proves it unavoidable.
