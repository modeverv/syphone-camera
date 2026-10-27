# Controlled zero-copy performance comparison

## Reproduce the camera comparison

Build and install the Release host and extension using the
[NativeCamera instructions](../../NativeCamera/README.md), with
`-configuration Release` instead of Debug. The two modes run from the same binary.
The installed extension must already be enabled. Build the
[verification consumer](../ZeroCopyVerification/README.md) once before measuring.
These commands control only the project's host and verification consumer, and
leave the host stopped after each run. Output directories must be new.

```sh
python3 Tools/ZeroCopyBenchmark/run-comparison.py --check-only \
  --output build/my-zero-copy-preflight
python3 Tools/ZeroCopyBenchmark/run-comparison.py --warmup 8 --duration 40 \
  --output build/my-zero-copy-comparison
```

Preflight runs both modes with image stamps/hashes and source correlation enabled.
Performance runs use `zero-copy, gpu-copy, gpu-copy, zero-copy, gpu-copy,
zero-copy, zero-copy, gpu-copy`. Each run starts a fresh host and consumer, waits
for both streams to be active, warms up for 8 seconds, then samples for 40 seconds
at 5 second intervals. The consumer stays active beyond that window, so final
report serialization and shutdown are excluded from CPU measurements.
`--copy-first` swaps both modes while retaining balanced order. Each run rejects
source throughput outside 29.5–30.5 fps rather than treating fewer frames as lower cost.

Analyze all completed runs offline:

```sh
python3 Tools/ZeroCopyBenchmark/analyze.py build/my-zero-copy-comparison
```

This writes `analysis.json` and `analysis.md`, checks matching-throughput and
metadata-only capture conditions, and reports run ranges and adjacent paired
differences. `--allow-partial` is for progress checks. See the
[2026-10-27 measured results](../../Docs/NATIVE_ZERO_COPY_PERFORMANCE.md).

The comparison scratch is IOSurface-backed BGRA with the same row stride and
Metal storage mode as the final pool. The only additional image operation is
one full-size blit. `renderer-check.swift` compares complete pixel bytes for the
same four sequence values without opening a camera:

```sh
mkdir -p build/zero-copy-benchmark
xcrun swiftc -O NativeCamera/Host/NativeCameraSink.swift \
  NativeCamera/Host/SurfacePatternRenderer.swift \
  Tools/ZeroCopyBenchmark/renderer-check.swift \
  -o build/zero-copy-benchmark/renderer-check
build/zero-copy-benchmark/renderer-check
```

`sample-processes.py` measures existing processes without opening a camera,
starting or stopping an application, requesting elevated privileges, or changing
system settings. The caller owns the A/B workload and identifies exact PIDs.

## CPU and resident memory sampling

```sh
python3 Tools/ZeroCopyBenchmark/sample-processes.py --self-test
python3 Tools/ZeroCopyBenchmark/sample-processes.py \
  --duration 30 --interval 5 \
  --pid host=1234 --pid extension=1235 --pid consumer=1236 \
  --pid camera_service=1237 \
  --output /absolute/path/process-metrics.json \
  --csv /absolute/path/process-metrics.csv
```

Replace every PID with the current process. Do not copy old PIDs from an earlier
run. `--pid` can be repeated; labels and PIDs must be unique. Confirm the extension
executable belongs to `com.dream-jack.syphoncamera.probe.camera`. The relevant
shared macOS camera service on the measured Mac is `cameracaptured`; its CPU can
also contain work for unrelated camera clients, so keep those clients consistent.

The report uses cumulative CPU time differences over measured monotonic wall
time. **100% is one fully occupied CPU core**, not all cores combined. It never
uses `ps %CPU`, which is a smoothed history rather than the chosen interval.

- For permitted PIDs, `proc_pid_rusage(RUSAGE_INFO_V0)` supplies cumulative user
  and system time, RSS, physical footprint, wakeups, and process-start identity.
  On this Apple Silicon runtime CPU counters are Mach absolute-time ticks, so
  they are converted with `mach_timebase_info`. The self-test checks the
  conversion against `getrusage(RUSAGE_SELF)` during a short CPU workload.
- For protected service PIDs, the syscall returns `EPERM`. A single batched
  `/bin/ps` call per sample reads cumulative `TIME`, RSS, and start time. This
  fallback has 10 ms CPU-counter resolution, which is disclosed per sample.
  The full-window average is more useful than individual one-second intervals.
  `/bin/ps` startup is measurable (about 40 ms CPU per invocation in the initial
  local smoke test). Use 5 s or longer intervals for lower observer overhead;
  increasing the interval does not reduce full-window cumulative CPU precision.
- PID disappearance, changed start identity, or decreasing CPU counters marks
  the report incomplete. Missing measurements are not interpreted as zero.
- `summaries` contains full-window CPU percentage and RSS median/maximum/last.
  Raw snapshots and optional CSV permit independent recalculation.
  RSS is per-process resident memory; summing RSS across shared-`IOSurface`
  processes can double-count shared storage and is not a memory-allocation total.
- `measurementOverhead` records this Python process's CPU plus its `ps` children.
  It excludes startup/import and final JSON serialization; it covers the actual
  sample window. JSON is written once, after sampling.

Darwin's public `rusage_info_v0` through `v6` structures do not expose GPU time.
The sampler deliberately writes GPU availability as absent, not measured zero.
The native source's completed Metal command timestamps provide an independent
GPU-duration measurement; this is command execution time, not device utilization
or watts. Installed `mactop --headless --pid PID` also exposes `gpu_ms_per_sec`,
but its first sample is a warm-up and it collects other machine metrics. It is
not launched by this sampler.

The local declarations were checked against the installed Darwin SDK headers.
Apple's XNU source documents the [same-user permission check for PID rusage](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c)
and the [task resource counters](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c).

## A/B conditions

Use the same native Metal pattern, 1920×1080 BGRA at 30 fps, the same Camera
Extension and the same device-native AVFoundation consumer for both modes.
Disable hashing, image stamps, PNG export, frame-retention stress, and detailed
per-frame diagnostic logging during performance measurement. Check correctness
separately before timing.

Warm each mode before sampling, then alternate the order across repeated runs.
Record frame rate and drops alongside CPU/GPU metrics; lower CPU from failing to
deliver frames is not an improvement. Compare run means and their variation,
rather than presenting one favorable one-second sample. Keep unrelated workloads
as stable as possible and disclose that shared service/system metrics include
other applications.

The comparison isolates one GPU copy inside the native test source. It is not a
benchmark of stock WMC against the new backend, because stock WMC cannot supply
the immutable, correctly typed buffers required by that backend. It also does
not reproduce the existing UniCamEx bridge's full pipeline or its flip shader.
