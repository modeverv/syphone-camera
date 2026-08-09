# UniCamEx integration notes

## Intent

This project depends on UniCamEx as an external, installed virtual-camera backend.

## Integration options

### Option A: direct texture-send API

If the upstream UniCamEx checkout on the target Mac exports a public API equivalent to sending `MTLTexture` directly, prefer that.

Benefits:
- smallest bridge surface area
- likely simplest route to good performance

### Option B: direct sample-buffer send path

If direct texture send is not practical, check whether upstream provides a direct `CMSampleBuffer` or `CVPixelBuffer` send path.

### Option C: sink-stream producer path

If neither A nor B is straightforward, inspect the upstream source and write against the sink-stream producer mechanism directly.

## Strong rule

Codex should adapt to the **actual current upstream API** rather than treating the symbols in this handoff as canonical.
