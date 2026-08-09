# Syphon UniCamEx Bridge

An experimental macOS bridge that sends a Syphon video stream to the
[UniCamEx](https://github.com/creativeIKEP/UniCamEx) virtual camera.

It is intended for workflows such as:

```text
Webcam Motion Capture -> Syphon -> this bridge -> UniCamEx -> Chrome / Google Meet
```

The bridge is a small native macOS app. It does not implement its own
CoreMediaIO Camera Extension and does not require OBS in the video path.

## Status

The following path has been verified on the maintainer's Mac:

- macOS 26.5.1, arm64
- Xcode 26.6
- UniCamEx v1.2.0
- moving diagnostic pattern through the UniCamEx camera
- Webcam Motion Capture's Syphon output through the UniCamEx camera
- QuickTime Player camera preview
- newest-frame-wins queue with effective depth 1

This repository is currently source-first and experimental. It does not
provide a notarized or pre-signed application. Your Mac must have a usable
UniCamEx installation, and the project may need adjustments for newer
UniCamEx, Syphon, Xcode, or macOS releases.

## Requirements

- macOS 13 or later
- Apple Silicon or Intel Mac supported by the installed toolchain
- Xcode and command-line tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [UniCamEx](https://github.com/creativeIKEP/UniCamEx) **release binary**, installed
  separately before building or running this bridge
- [Syphon Framework](https://github.com/Syphon/Syphon-Framework)
- A Syphon-producing application, for example Webcam Motion Capture

The project currently expects the Syphon framework at
`Vendor/Syphon-Framework/DerivedData/Build/Products/Release/Syphon.framework`.
The bootstrap script prepares the upstream checkouts; building the framework
may still be required on a new machine.

## Quick start

Clone the repository and prepare the upstream references:

```bash
git clone <repository-url>
cd syphon-camera
./scripts/bootstrap.sh
```

Before building or running the bridge, install the UniCamEx release binary on
the target Mac and complete any required approval steps. The UniCamEx source
checkout prepared by `bootstrap.sh` is only a development reference; it does
not install or activate the virtual camera.

Generate the Xcode project and build the bridge:

```bash
xcodegen generate
make build
```

Launch the app with:

```bash
make run
```

The default source is the moving diagnostic pattern. Select `UniCamEx` in
QuickTime Player via **File > New Movie Recording** and confirm that the
pattern is visible before testing a Syphon source.

To use Webcam Motion Capture:

1. Enable its Syphon output.
2. Start the bridge and select the Syphon source in the app.
3. Confirm that the `Webcam Motion Receiver/Webcam Motion Receiver` server is
   discovered.
4. Select `UniCamEx` in QuickTime, Chrome, or Google Meet.

If the Syphon server disappears, the bridge falls back to the diagnostic
pattern instead of blocking on an empty source.

## Experimental network H.264 transport

`SyphonUniCamExSender.app` and `SyphonUniCamExReceiver.app` are built and run
as separate macOS apps. UDP on port 5001 is the default. The sender app lets
you select **Test Pattern** or **Syphon**; it prefers a detected WMC-related
server, then falls back to the first available Syphon server.

On the receiving Mac (with UniCamEx installed):

```bash
make run-receiver NETWORK_PORT=5001
```

On the sending Mac:

```bash
make run-sender NETWORK_HOST=192.168.1.42 NETWORK_PORT=5001
```

For a same-Mac loopback test:

```bash
make run-network
```

The UDP sender fragments each H.264 frame into datagrams of at most 1,200
bytes. The receiver drops an incomplete frame after one second, preferring a
newer frame over retransmission delay. This is appropriate only on a trusted
LAN: it currently has no authentication, encryption, congestion control,
FEC/NACK, or adaptive bitrate. Use WebRTC before exposing this path to the
public internet.

## Build options

The Makefile defaults to an unsigned local build:

```bash
make build
```

The output is written under `build/Build/Products/Debug/`. Override the
configuration or derived-data directory if needed:

```bash
make build CONFIGURATION=Release DERIVED_DATA=build-release
```

`CODE_SIGNING_ALLOWED=NO` is the default for local development. A signed,
installable, and notarized distribution requires the developer to configure
their own Apple Developer identity, bundle identifiers, entitlements, and
distribution process. This project does not claim that an unsigned build can
activate a camera extension.

## Architecture

```text
FrameSource
  ├─ TestPatternFrameSource
  └─ SyphonFrameSource
          |
          v
    BridgeEngine
          |
          v
    UniCamExSender
          |
          v
  UniCamEx sink stream
          |
          v
  UniCamEx virtual camera
```

The current UniCamEx v1.2.0 path uses IOSurface-backed 1920x1080 BGRA pixel
buffers and a CoreMediaIO sink stream. The Syphon texture is converted on the
GPU before it is wrapped in a sample buffer. The bridge keeps only the newest
frame and avoids a CPU pixel readback in the steady-state path.

## Performance notes

The documented reference run measured approximately 16.8–18.8% bridge CPU,
about 100 MB RSS, and 8.66 ms average from Syphon publication to bridge
dispatch over a sustained 30 fps sample. These are machine- and workload-
dependent measurements, not performance guarantees. See
[`Docs/PERFORMANCE.md`](Docs/PERFORMANCE.md) and
[`Docs/ZERO_COPY_AUDIT.md`](Docs/ZERO_COPY_AUDIT.md).

On 2026-08-09, a same-Mac UDP H.264 loopback at 1920x1080 / 30 fps with the
diagnostic pattern measured 10.5 ms average sender-to-UniCamEx enqueue latency,
30.3 effective fps, and 0.5–0.7 Mbps. Receiver CPU was about 18%; sender CPU
was about 100% with about 109 MB RSS. The sender result includes CPU-based
1080p diagnostic-pattern generation and is not a Syphon-input measurement.
The corresponding TCP comparison was about 22 ms. These are local reference
measurements, not guarantees for a two-Mac network.

## Documentation

- [`Docs/BUILD_AND_RUN.md`](Docs/BUILD_AND_RUN.md) — build and runtime checks
- [`Docs/DESIGN.md`](Docs/DESIGN.md) — architecture and trade-offs
- [`Docs/RUNTIME_NOTES.md`](Docs/RUNTIME_NOTES.md) — verified environment notes
- [`Docs/TEST_PLAN.md`](Docs/TEST_PLAN.md) — acceptance checks
- [`Docs/CODEX_HANDOFF.md`](Docs/CODEX_HANDOFF.md) — historical implementation work order

## Troubleshooting

- **`xcodegen` not found:** install it with `brew install xcodegen`.
- **Syphon framework not found:** build the checkout under `Vendor/Syphon-Framework`
  and confirm the framework path in `project.yml`.
- **UniCamEx is not listed:** install and approve UniCamEx according to its
  release instructions, then restart the camera client.
- **Black preview:** verify that the UniCamEx stream is available and that
  the source is producing frames. The current adapter requires IOSurface-backed
  pixel buffers and UniCamEx v1.2.0's 1920x1080 BGRA format.
- **Signed distribution questions:** local unsigned builds and a distributable
  camera extension are different cases; configure a suitable Apple Developer
  team and entitlements before attempting distribution.
- **No remote video:** allow UDP/5001 on the receiver, confirm that
  `NETWORK_HOST` is the receiver's LAN address, and use the same
  `NETWORK_TRANSPORT` on both endpoints.

## Contributing

Bug reports and pull requests are welcome. Please include:

- macOS and Xcode versions
- Mac architecture
- UniCamEx and Syphon versions
- source application and output client
- relevant build or runtime logs

Performance changes should include measurements for CPU, memory, frame rate,
queue depth, and latency where possible. Avoid introducing an unbounded frame
queue or a CPU readback in the hot path.

## License

This project is licensed under the [MIT License](LICENSE).
