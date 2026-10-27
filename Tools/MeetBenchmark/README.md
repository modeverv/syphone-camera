# Actual Meet send verification

`analyze-webrtc.py` reads a manually exported **WebRTC-internals JSON** dump
(`.txt`, `.json`, or gzip `.gz`). It never opens Chrome, a camera, a microphone,
or a meeting. It does not support the separate line-oriented RTCStatsDump format.

The Chrome internal page may be unavailable to browser automation. A user can
open it and export the diagnostic dump manually; this tool only reads that saved
local file. No browser security policy workaround is part of this workflow.

The native camera defaults to 1080p/30; 720p/30 is optional. The
[2026-10-27 results](../../Docs/NATIVE_CAMERA_MEET_PERFORMANCE.md) distinguish
completed CPU measurements from the unconfirmed two-condition RTP comparison.

## Capture conditions

Use the same animated virtual-camera source at 1080p30 and 720p30. Use only the
intended virtual camera and keep microphones off. Both CPU measurement runs
need an actual second participant viewing the sender at the same tile size;
do not compare a local preview with a network call. Prefer a separate receiver
device or a separately measured browser instance so receive/decode work does not
silently enter the sender's CPU total.

Select Meet's maximum send resolution, then verify the actual result. Google
documents the setting as a maximum and limits 1080p sending to eligible accounts
and capable devices. [Meet video settings](https://support.google.com/meet/answer/9302964?co=GENIE.Platform%3DDesktop&hl=en)

Google's group-meeting 1080p launch documentation requires a participant to pin
the sender in a sufficiently large view, and describes automatic reduction under
bandwidth constraints. Keep the remote sender tile pinned and large for both
conditions. [Google's 1080p behavior](https://workspaceupdates.googleblog.com/2023/10/full-hd-resolution-for-group-meetings-google-meet.html?hl=en)

Open WebRTC-internals **before joining** the test call and export its normal
WebRTC-internals dump **immediately after the measured windows and before leaving**.
Current Chromium retains at most 1000 points per series and removes closed
connections from this store by default. Verify retained timestamps; a later file
save does not recover expired data. Keep raw dumps under an ignored local
evidence directory; they may contain meeting URLs, device labels, and network
addresses. The analyzer outputs only the Meet origin and a hash of the full URL.

## Analyze the same window as CPU samples

From the repository root:

```sh
python3 Tools/MeetBenchmark/sample-window.py \
  --resolution 1080p --source-kind syphon --duration 40 --interval 5 \
  --pid meet_sender=12345 --pid meet_receiver=23456 --all-chrome \
  --output-dir /absolute/1080p-window
```

Use current, independently identified process IDs; these example IDs are
placeholders. The output directory must be new. The sampler requires fresh
running-producer telemetry at the requested dimensions, an active extension
consumer, and advancing source frames during preflight. For the synthetic Metal
source, use `--source-kind native-pattern`. Its `cpu.json` records cumulative
per-process CPU counters and the exact measurement window. System CPU covers
the entire Mac, including background processes and the observer. `allChrome`
includes the receiver, shared services, and unrelated tabs; it is invalidated
when the Chrome PID roster changes. Neither CPU sampling nor source FPS alone
proves network sending.

For the optional 720p condition, use `--resolution 720p` and a separate output
directory. Match the analyzer's expected dimensions to the condition being
checked; the actual encoded result can still be lower than that target.

```sh
python3 Tools/MeetBenchmark/analyze-webrtc.py /absolute/webrtc_internals_dump.txt \
  --process-samples /absolute/1080p-window/cpu.json \
  --expected-width 1920 --expected-height 1080 --expected-fps 30 \
  --output /absolute/1080p-network-analysis.json
```

Or provide an explicit UTC interval:

```sh
python3 Tools/MeetBenchmark/analyze-webrtc.py /absolute/webrtc_internals_dump.txt \
  --start-utc '2026-10-27T06:00:00Z' --end-utc '2026-10-27T06:00:40Z' \
  --expected-width 1280 --expected-height 720 --expected-fps 30 \
  --output /absolute/720p-network-analysis.json
```

`--process-samples` accepts the JSON from
[`sample-processes.py`](../ZeroCopyBenchmark/sample-processes.py) and aligns the
WebRTC sample interval to its UTC collection window. Each stream uses actual
samples inside that window and reports the exact covered span. It does not
interpolate counters to manufacture matching boundaries. `--pc-id` can select
one connection if several Meet tabs were present. The default minimum observed
span is 10 seconds, coverage must reach 90% of the requested CPU window, and
expected frame-rate tolerance is ±1 fps.

For a receiver-side dump use `--require-direction inbound`; proof then requires
increasing received bytes and decoded frames. A sender's remote-inbound RTCP
report can describe the SFU, so it is not equivalent to receiver-side decoding.

## Interpretation

- Actual outbound media requires increasing `framesSent` **and** `bytesSent`.
  `active=true`, source dimensions, preview, or encoded frames alone are insufficient.
- Encoded `frameWidth` / `frameHeight` can be smaller than camera input. Every
  active encoding/SSRC is reported individually, with actual frame rate, payload
  bitrate, codec, and quality-limitation reason/duration. Simulcast frame rates
  are not added together. Referenced `media-source` records separately show
  Chrome's camera input dimensions and frame-counter rate, where retained.
- The target is confirmed only when at least one sending stream sustains the
  expected dimensions and frame rate within its measured window. Downscaling is
  reported as not-confirmed rather than called 1080p based on camera settings.
- Byte counters include retransmissions but omit IP/UDP overhead; this is video
  RTP traffic, not total network-interface usage.
- Match the reported peer-connection renderer PID to sampled processes. Browser
  GPU/network services are shared; whole-browser CPU cannot automatically be
  labeled sender-only or Meet-only. The tool does not create such a total.

These distinctions follow the [WebRTC statistics definitions](https://www.w3.org/TR/webrtc-stats/).

The parser uses Chromium's explicit per-object timestamp series from
[`stats_graph_helper.js`](https://raw.githubusercontent.com/chromium/chromium/main/content/browser/webrtc/resources/stats_graph_helper.js),
the serialized arrays in
[`data_series.js`](https://raw.githubusercontent.com/chromium/chromium/main/content/browser/webrtc/resources/data_series.js),
and the export schema in
[`dump_creator.js`](https://raw.githubusercontent.com/chromium/chromium/main/content/browser/webrtc/resources/dump_creator.js).
It rejects missing timestamp alignment rather than assuming 1 Hz sample spacing.

When only visible Meet webpage observations are available, remote video
`videoWidth`/`videoHeight` and advancing `currentTime` can support that the
identified remote participant is playing at the observed dimensions. They do
not establish an actual frame rate, outbound encoding size, or network bitrate.
The playback-quality total frame counter, if available, includes displayed and
dropped frames, including frames dropped before decoding; it is not a decoded
frame counter. See [Media Playback Quality](https://w3c.github.io/media-playback-quality/).

```sh
python3 Tools/MeetBenchmark/analyze-webrtc.py --self-test
```

Exit 0 means the requested evidence was confirmed; exit 1 means not-confirmed.
The tool still writes the report in the latter case. Synthetic self-tests cover
send counters, downscaled output, no-frame-send, counter resets, missing timestamps,
and preview-only evidence. A real gzipped Chromium export was also parsed on
2026-10-27, with sender and receiver streams independently identified. Chromium's
1000-point retention in an earlier export had removed three measurement windows;
those windows remained unconfirmed. A partially retained instantaneous FPS
series was omitted, while complete cumulative frame counters provided actual
FPS. Do not assume every exported field covers the same time range.
