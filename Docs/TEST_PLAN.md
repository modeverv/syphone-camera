# Test Plan

## T0 — build

- [ ] `xcodegen generate`
- [ ] Debug build succeeds
- [ ] no unresolved Syphon symbols in Test Pattern build
- [ ] app bundle contains Camera Extension

## T1 — extension registration

- [ ] app copied to `/Applications`
- [ ] Activate button submits request
- [ ] user approval handled
- [ ] `Syphon Camera` appears in QuickTime camera list
- [ ] camera remains registered after host window closes

## T2 — sink transport

- [ ] Start Test Pattern
- [ ] moving pattern appears in QuickTime
- [ ] moving pattern appears in browser Google Meet preview
- [ ] stopping bridge freezes/falls back without crashing Meet
- [ ] starting bridge again resumes

## T3 — backpressure

Artificially make producer 60 fps while output stream remains 30 fps.

- [ ] memory stable for 10 minutes
- [ ] latency does not continuously rise
- [ ] queue stays bounded
- [ ] dropped frames acceptable

## T4 — Syphon discovery

With Webcam Motion Capture / receiver output active:

- [ ] server appears in list
- [ ] displayed app/server name is correct
- [ ] selected server connects
- [ ] server exit does not crash bridge
- [ ] server restart can reconnect

## T5 — format

- [ ] 1280×720 BGRA exact-size works
- [ ] incompatible source produces clear warning
- [ ] after scaler implementation: 1920×1080 works
- [ ] aspect ratio policy verified

## T6 — meeting apps

- [ ] Google Meet
- [ ] Zoom
- [ ] Microsoft Teams if installed
- [ ] QuickTime Player

## T7 — performance

Record for 10 minutes:
- host CPU
- extension CPU
- host RSS
- extension RSS
- GPU activity
- dropped frames

Compare against OBS using:
- Syphon source
- one 1280×720 scene
- OBS Virtual Camera
- no recording/streaming

## T8 — soak

- [ ] 2-hour Meet call
- [ ] sleep/wake
- [ ] WMC restart
- [ ] browser tab close/reopen
- [ ] camera deselect/reselect
