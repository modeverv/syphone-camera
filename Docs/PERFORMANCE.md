# Performance Budget

## Baseline target

1280×720 @ 30 fps.

Raw BGRA payload:

```text
1280 × 720 × 4 × 30 ≈ 110.6 MB/s
```

That number is memory traffic, not encoded network traffic.

## Expected bridge work

Per accepted frame:

1. Syphon exposes an existing Metal texture.
2. Acquire a pooled CVPixelBuffer.
3. Exact-size case: one GPU blit.
4. Wrap pixel buffer in CMSampleBuffer.
5. Enqueue pointer to CMIO sink.
6. Extension forwards the buffer.

There is intentionally no encode/decode stage.

## Avoid

- `MTLTexture.getBytes`
- `CGImage`
- `NSImage`
- `CIContext` on CPU
- unbounded DispatchQueue work items
- converting every frame to PNG/JPEG
- websocket/localhost transport
- shared-memory memcpy loops if CMIO sink works
- multiple frames buffered "for smoothness"

## Queue policy

Maximum useful queued video: one frame.

At 30 fps, every queued frame adds ~33 ms latency.

If producer > consumer:
- drop newest or oldest immediately
- current MVP drops incoming frames when CMIO queue is full

A later benchmark may prefer replacing pending/latest rather than dropping incoming, but the queue must stay O(1).

## Optimization order

1. correct live video
2. remove obvious CPU copies
3. fix resolution mismatch on GPU
4. remove `waitUntilCompleted()`
5. only then investigate BGRA → NV12

Do not optimize CMIO internals before an Instruments trace shows a real cost.
