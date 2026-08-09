# Zero-copy plan

## Definitions

### Level 0
Working, but CPU pixel copies exist.

### Level 1
No CPU pixel copies. One GPU conversion/blit may exist.

### Level 2
No CPU pixel copies, no per-frame allocations, same queue depth target.

### Level 3
Same-IOSurface or equivalent reference-only transport where technically possible, plus no per-frame allocations after warm-up.

## Boundaries to audit

- Syphon server -> bridge texture
- bridge texture -> UniCamEx handoff
- UniCamEx handoff -> visible camera feed

## Rules

- no CPU texture readback in steady state
- no pixel-plane memcpy in steady state
- no unbounded queue
- drop stale frames instead of accumulating latency
- document unavoidable GPU conversion separately from CPU copies
