# Performance notes

These are the earlier UniCamEx bridge's targets and measurements. Current native
camera results are in the [30 fps resolution comparison](NATIVE_CAMERA_MEET_PERFORMANCE.md)
and the separate [native GPU-copy comparison](NATIVE_ZERO_COPY_PERFORMANCE.md).
The desired values below are goals from that earlier work, not new measurements.

## Measurement priorities

1. CPU percent of the bridge app
2. Memory footprint of the bridge app
3. End-to-end frame latency
4. Frame stability at 1280x720 @ 30 fps
5. Whether any CPU pixel copies occur

## Expected phases

### Phase 0
Test pattern only. This proves the UniCamEx path.

### Phase 1
Syphon integrated. Probably acceptable even if there is one GPU conversion.

### Phase 2
Copy audit and optimization.

## Tools to use on the target Mac

- Activity Monitor
- Instruments: Time Profiler
- Instruments: Allocations
- Instruments: Metal System Trace (if needed)
- `os_signpost` or unified logging timestamps

## Desired steady state

- CPU: low single digits or below
- memory: small and stable
- no frame queue growth
- no per-frame heap churn after warm-up
- no CPU memcpy of pixel data

## Baseline and current implementation

Environment recorded in `Docs/RUNTIME_NOTES.md`: arm64 macOS 26.5.1, Xcode 26.6, UniCamEx v1.2.0, WMC Syphon source at 1920x1080. Existing sustained observations were approximately 16.5–18.8% bridge CPU, 97,312 KB RSS, 300 accepted frames with 0 observed sink-pressure drops, and 8.66 ms average Syphon-publication-to-dispatch latency over the recorded run.

The 2026-08-11 live verification used WMC's `Webcam Motion Receiver/Webcam Motion Receiver` server at 1920x1080 and the workspace Debug bridge for over 60 seconds. The direct IOSurface probe failed at stage 2 (`CVPixelBufferCreateWithIOSurface`: `-6661 invalid-argument`), while the production route selected `METAL_BLIT`. The bridge reported `enqueued=3900 dropped=1 metal_blit=3900 ci_render=0`, with 8.66-8.71 ms average texture-to-enqueue latency. `mactop` samples near the end reported about 20.5-21.5% bridge CPU, 96,032 KB RSS, and 10.2-13.0 ms/s process GPU time; thermal state remained normal. This is a live WMC bridge measurement, not an end-to-end Meet display measurement.
