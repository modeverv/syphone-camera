# syphon-unicamex

A Codex handoff package for building a lightweight macOS bridge:

```text
Webcam Motion Capture -> Syphon -> tiny bridge app -> UniCamEx virtual camera -> Google Meet
```

## Why this architecture

- Do **not** build/sign our own CoreMediaIO Camera Extension first.
- Reuse the already-signed **UniCamEx** virtual camera extension/app as the camera backend.
- Build only a normal macOS producer/bridge app.
- First make it work with a moving test pattern.
- Then feed Syphon frames from Webcam Motion Capture.
- Then optimize toward zero-copy.

## Start here

1. Read `Docs/CODEX_HANDOFF.md`
2. On the target Mac, run:

```bash
./scripts/bootstrap.sh
```

3. Then give Codex this prompt:

```text
Read Docs/CODEX_HANDOFF.md and treat it as the work order.
Start with Phase 0 only.
Do not touch Syphon until the test-pattern path into UniCamEx works.
```
