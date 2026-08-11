# Direct IOSurface probe

Status: diagnostic-only; not selected for production, 2026-08-11.

## Purpose

The bridge probes whether the Syphon `MTLTexture` IOSurface can be wrapped as a UniCamEx-compatible image buffer. The probe runs once after the first texture accepted by the sink gate. It never retries the operation per frame and never enqueues the probe buffer.

## Stages

| Stage | Operation | Current behavior |
| --- | --- | --- |
| 1 | Retrieve `texture.iosurface` | Logs presence or absence. |
| 2 | `CVPixelBufferCreateWithIOSurface` | Runs once; logs the exact `CVReturn` and a readable common status name. |
| 3 | `CMVideoFormatDescriptionCreateForImageBuffer` | Runs only after stage 2 succeeds; logs `OSStatus`. |
| 4 | `CMSampleBufferCreateReadyWithImageBuffer` | Runs only after stage 3 succeeds; logs `OSStatus`. |
| 5 | Enqueue into UniCamEx sink | Intentionally not attempted by the probe. |
| 6 | UniCamEx asynchronous consumption | Intentionally not attempted by the probe. |
| 7 | Visible frame in QuickTime/Chrome/Meet | Intentionally not attempted by the probe. |

Stages 5–7 require changing the production sink state and validating external ownership/lifetime over an asynchronous consumer interval. A successful wrapper and sample-buffer construction is therefore not reported as zero-copy support.

## Production routing

For exact 1920×1080 `.bgra8Unorm` input, the sender uses a persistent `CVMetalTextureCache` and one GPU blit into the warmed IOSurface-backed pool buffer. It reports `METAL_BLIT` and emits the `MetalBlit` signpost. If the format, dimensions, texture-cache operation, or command buffer completion is incompatible, the sender uses `CORE_IMAGE_FALLBACK`; non-exact inputs retain the scale-and-center compatibility path.

Neither route performs CPU pixel readback or CPU pixel-plane `memcpy` in the WMC texture path. `METAL_BLIT` is one GPU copy, not zero-copy.

## Runtime evidence requirement

The probe report must be captured from the workspace build while a live WMC Syphon server is publishing. The report must be paired with moving-frame verification through UniCamEx and a sustained measurement. In the current environment WMC Capture/Receiver can be launched, but no Syphon server was observed during the latest runs; no live WMC probe status or Metal-vs-CI performance claim is made.
