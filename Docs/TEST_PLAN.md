# Test plan

## Phase 0: UniCamEx path only

- [x] UniCamEx camera appears in QuickTime or similar
- [x] Bridge app launches
- [x] Test pattern animates locally in bridge preview (if implemented)
- [x] Test pattern appears through UniCamEx camera in QuickTime
- [x] Chrome enumerates UniCamEx
- [x] Google Meet displays the test pattern

## Phase 1: Syphon path

- [x] WMC Syphon output enabled
- [x] Bridge discovers the Syphon server
- [x] Frames appear through UniCamEx camera
- [x] Meet shows the incoming frames (user-confirmed for the bridge path; WMC live frame in QuickTime confirmed)
- [x] Stopping WMC falls back cleanly to diagnostic frame

## Phase 2: performance

- [ ] No unbounded queue
- [ ] No per-frame allocation after warm-up
- [ ] No CPU readback
- [ ] Zero-copy audit written
- [ ] Latency measured and documented
