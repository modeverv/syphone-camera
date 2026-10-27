# Zero-copy verification consumer

This local macOS app receives only an exact, uniquely matching external camera
(default: `Syphon Zero Copy Camera`). It never falls back to a physical/default
camera and never creates an audio input. Camera access uses the normal macOS
permission prompt. Its ad-hoc signature needs no Apple Developer portal changes.

## Build and self-test

From the repository root:

```sh
python3 Tools/ZeroCopyVerification/build.py
Tools/ZeroCopyVerification/build/ZeroCopyVerifier.app/Contents/MacOS/ZeroCopyVerifier --self-test
```

The self-test opens no camera. It verifies exact rational PTS matching, rejection
of reused IOSurface IDs with a different PTS, rejection of different surfaces and
source sequence mismatches, duplicate trace rejection, and stamp/hash corruption
detection on a locally allocated IOSurface-backed pixel buffer.

## Capture and verify

Launch the app with absolute result paths. The app exits after `--duration` seconds
of capture or `--max-frames`, whichever comes first. The first camera permission
prompt has a separate bounded timeout (`--authorization-timeout`, default 90 s).

```sh
open -n -W Tools/ZeroCopyVerification/build/ZeroCopyVerifier.app --args \
  --name 'Syphon Zero Copy Camera' \
  --duration 10 --max-frames 600 --minimum-frames 100 \
  --report /absolute/path/verification.json \
  --source-trace /absolute/path/submitted.jsonl \
  --validate-stamp --hash-pixels --hold-ms 200 --hold-count 3 \
  --first-png /absolute/path/first-frame.png
```

Use `--unique-id` instead of name matching when needed. There is no prefix/fuzzy
match. `open -W` waits for the app but its exit code is not the app's result; inspect
the JSON `status` field. Direct executable invocation provides the verifier's exit
code, but may attribute camera permission to the invoking terminal/app.

The output requests `videoSettings = [:]`, Apple's documented request for
device-native samples. It sets no pixel format, dimensions, transform or frame-rate
conversion. The report records actual active format, session preset and received
sample format. `nil` is deliberately avoided because it requests a default
uncompressed format, which can introduce a conversion. See [Apple's videoSettings
documentation](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/videosettings).

## Source trace contract

Append and flush one JSON line per submitted frame:

```json
{"event":"submitted","sequence":1,"surfaceID":123,"ptsValue":123456789000,"ptsTimescale":1000000000}
```

The verifier reads this trace when capture finishes. It matches both IOSurface ID
and exactly equal rational presentation timestamp, with epoch zero on the source.
Matching surface ID alone is insufficient because IDs/pool buffers are reused.
Missing matches, malformed trace lines, and duplicate surface/PTS keys fail the
requested source correlation.

Optional `--validate-stamp` expects sequence bytes in the B channels of the first
eight BGRA pixels, little-endian UInt64. Each of those pixels must have G=`0x5a`,
R=`0xa5`, A=`0xff`. It checks the signature and compares the decoded sequence with
the matched source trace. This stamp is a test-source protocol, not a requirement
on real Syphon video.

## What the result proves

- `sourceCorrelation.sameSurfaceAndPTSConfirmed` records exact surface/timestamp
  sharing for every received frame in the trace, with optional sequence checking.
- Per-frame records include IOSurface ID/seed, PTS, dimensions, native pixel format,
  stride, optional SHA-256, and optional decoded sequence.
- `--hold-ms` retains pixel buffers for the chosen interval, up to `--hold-count`
  concurrent buffers, and hashes them before/after. `retentionMutations` must be zero.
  Holding is asynchronous, so the callback continues receiving frames while those
  earlier buffers remain retained. This tests producer reuse under back pressure.
- Received/dropped frame counts, unique hashes/stamps, and no-IOSurface frames are
  reported. The JSON `frames` array is bounded by `--max-frames` (maximum 10,000).

Hashing, stamp inspection, retained-buffer checks, and PNG export intentionally
read or render pixels **inside this diagnostic consumer only**. They are optional
and are not part of the production transfer path. Hashes include native row
padding; compare them only under this documented scope. Metadata-only capture
uses none of those pixel readbacks.

`status: passed` means the selected checks passed. Without `--source-trace`, it is
only a functional capture check and does not establish zero-copy transport. Even
with correlation, it proves the traced source-to-this-consumer boundary; untraced
upstream producers and other applications require their own code audit/evidence.
The report never treats a texture wrapper or successful build as end-to-end proof.

## Offline correlation after capture

If macOS prevents the capture app from reading another app's container, copy the
source trace to an accessible evidence directory after capture, then recheck the
saved capture report. This does not open cameras or modify the original artifacts:

```sh
python3 Tools/ZeroCopyVerification/recheck-report.py \
  --recheck-report /absolute/path/capture.json \
  --source-trace /absolute/path/copied-submitted.jsonl \
  --report /absolute/path/capture-rechecked.json
python3 Tools/ZeroCopyVerification/recheck-report.py --self-test
```

The new full report preserves original capture/retention records and the previous
correlation result, records SHA-256 hashes of both input artifacts, and recomputes
the requested checks. The matching rule remains exact rational PTS equality; it
does not round timestamps or accept nearby PTS. If CoreMedia resamples the timebase,
the source must publish a timestamp exactly representable in that timebase, or
the report correctly records unmatched frames.

The installed app/binary is under ignored `build/`. Exit code is 0 for passing
requested checks, 1 for capture/evidence failure, and 2 for argument/report errors.
