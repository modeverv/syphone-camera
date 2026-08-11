# Runtime notes

Codex: append findings here.

## Environment

- macOS: 26.5.1 (25F80), arm64
- Xcode: 26.6 (17F113)
- architecture:
- Chrome:
- UniCamEx version: upstream checkout v1.2.0 in `Vendor/UniCamEx`; release installer not installed
- Syphon source/version: Syphon-Framework checkout (current upstream); framework target builds locally

## Phase 0

- build result: `xcodegen generate` and `xcodebuild ... build` succeeded with Xcode 26.6; local ad-hoc "Sign to Run Locally" signing
- runtime result: bridge running; UniCamEx installed from the signed v1.2.0 release installer
- how UniCamEx was installed: `UniCamExExtensionInstaller.zip` v1.2.0; camera appears as `UniCamEx`
- actual imported module names: no importable UniCamEx sender module; upstream exposes `UniCamEx.UniCamExSend(texture:)` inside its own bundle and uses CoreMediaIO internally
- deviations from scaffold: `UniCamExSender` discovers the `UniCamEx` AVCapture device, opens the second CoreMediaIO stream queue, and enqueues one newest sample buffer per consumer notification. UniCamEx v1.2.0 fixes its stream at 1920x1080 BGRA, so the Phase 0 test pattern uses 1920x1080. Pixel buffers must be IOSurface-backed; adding `kCVPixelBufferIOSurfacePropertiesKey` fixed the black output. Texture sending remains unsupported.
- QuickTime result: passed; UniCamEx selected in New Movie Recording and the moving color-bar test pattern was visible.
- Chrome result: user reports UniCamEx is selectable; live frame display remains to be checked.
- Meet result: user reports UniCamEx is selectable; live test-pattern display remains to be checked.

## Phase 1

- Syphon server name: `Webcam Motion Receiver/Webcam Motion Receiver` discovered and selected at runtime
- path used (direct texture / sample buffer / sink stream): SyphonMetalClient texture -> CIContext render into IOSurface-backed 1920x1080 BGRA CVPixelBuffer -> CMSampleBuffer -> UniCamEx sink stream
- resolution / fps: bridge output 1920x1080 @ 30 fps for UniCamEx v1.2.0; WMC input dimensions/fps not yet measured
- fallback behavior: verified; selecting Syphon with no server produces the deterministic moving test pattern through UniCamEx without hanging
- live result: passed; after restarting the Syphon source, QuickTime showed the WMC character frame through UniCamEx instead of the diagnostic pattern
- CPU:
- memory:
- latency notes:

## Phase 2

See `ZERO_COPY_AUDIT.md`. After disabling diagnostic-frame generation while a valid Syphon client is active, WMC run measured 16.5-18.8% CPU across 4 one-second samples and 97,312 KB RSS; WMC character frames remained visible through UniCamEx. `os_signpost` markers added at Syphon receipt, CI render, and UniCamEx enqueue.

### Queue pressure / latency measurement

- sustained sample: 300 accepted frames at 30 fps (about 10 seconds), WMC Syphon source active
- effective sender queue: depth 1; `enqueued=300`, `dropped=0`
- measured latency: average 8.66 ms from Syphon texture publication to bridge dispatch into the UniCamEx send path
- accompanying process samples: 17.9-18.9% CPU, 99,952 KB RSS
- scope note: this is publication-to-bridge-dispatch latency, not camera-driver display latency; the latter remains external to the bridge
- color/timing fix: texture-to-CI conversion now declares sRGB and renders with an explicit sRGB output color space; sample-buffer PTS now converts mach host ticks to nanoseconds using the mach timebase before creating the 30 fps sample timing.
- Meet note: the UniCamEx sink remains consumer-driven (`shouldEnqueue` follows the sink altered callback), so the Bridge cannot force frames into a consumer that requests approximately 1 fps. Correct timestamps remove one likely WebRTC pacing problem; Meet-side stats still need to confirm whether it requests 30 fps.
- Post-fix `mactop` check after Meet color/FPS recovery: 4 steady samples showed 17.9-18.6% CPU, 13.0-18.7 ms/s process GPU time, and 99,264 KB RSS. CPU is essentially unchanged from the prior 16.8-17.5% range; RSS is slightly lower and GPU time is within normal sample variation. The functional Meet improvement did not require a material Bridge CPU reduction.
- `mactop` headless CSV (5 samples at 1 s): Bridge process CPU settled at 16.8-17.5%, RSS 100,112-100,128 KB, process GPU time 18.0-22.4 ms/s; system GPU active was about 49-50%, with thermal state `正常`. The first sample included startup/warm-up and reported 0% for the process.
- OBS comparison: OBS 32.2.1 was started with the existing `サイフォンクライアント` scene and its virtual camera enabled. In the same WMC-active interval, OBS main process measured 21.9-23.2% CPU, 89.1-89.4 ms/s GPU time, and 286,752 KB RSS. Bridge measured 16.2% CPU, 19.4 ms/s GPU time, and 102,080 KB RSS in the paired run. These are process-level measurements; OBS helper processes and the camera extension are not included in the OBS main-process row.

### 2026-08-11 optimization verification

- Workspace build was launched explicitly from `DerivedData/Build/Products/Debug/SyphonUniCamExBridge.app`; this avoids confusing it with a same-named Xcode DerivedData application.
- The workspace build reached `Status: Running` at 1920x1080 @ 30 fps with the Test Pattern source. UniCamEx accepted sample buffers; the existing consumer-driven path remained active.
- WMC's `Webcam Motion Receiver/Webcam Motion Receiver` server was published and selected by the workspace bridge after Syphon output was enabled.
- The new probe is one-shot and logs through unified logging: texture/surface properties, direct wrap status, format-description status, sample-buffer status, and explicit non-attempt status for enqueue/consume/visible-frame stages.
- The direct IOSurface probe failed once at stage 2 with `-6661 (invalid-argument)`; stages 3-7 were intentionally not attempted. The exact-size sender then selected `METAL_BLIT` using the persistent cache/queue and did not invoke CI rendering.
- Every 300 enqueues, pipeline statistics now include `metal_blit` and `ci_render` conversion counts in addition to enqueue/drop counts and texture-to-enqueue latency.
- Sustained live run: `enqueued=3900`, `dropped=1`, `metal_blit=3900`, `ci_render=0`, average latency 8.66-8.71 ms; near-run process samples were 20.5-21.5% CPU, 96,032 KB RSS, and 10.2-13.0 ms/s GPU time, with normal thermal state.
