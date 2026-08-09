# Performance notes

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
