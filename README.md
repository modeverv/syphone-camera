# Syphon Camera

Experimental macOS apps that send Syphon video to a virtual camera. The native
backend includes its own Camera Extension; the existing bridge uses
[UniCamEx](https://github.com/creativeIKEP/UniCamEx).

The native backend defaults to **1920×1080 at 30 fps**. **1280×720 at 30 fps is
an optional output setting**. Neither path needs OBS.

```text
Webcam Motion Receiver -> Syphon -> NativeCamera -> Syphon Zero Copy Camera -> Meet / Zoom
                                  or BridgeApp -> UniCamEx                  -> camera client
```

## Status

As of 2026-10-27, the native development build is **Host 6 / Camera Extension 4**.
Company-team signing and extension activation were verified with SIP enabled.
Stock Webcam Motion Receiver (WMC) input works at both resolutions. Each admitted
30 Hz tick samples the current Syphon texture and uses one GPU pass to resize
and vertically flip it into the final IOSurface-backed pixel buffer. The
extension forwards the same sample buffer. The native adapter and extension
perform no CPU pixel copy, but the WMC input path is **not end-to-end zero-copy**: its mutable source
texture still requires the GPU conversion.

The native Metal diagnostic source renders directly into its final IOSurface.
Its [sharing and retained-frame checks](Docs/NATIVE_ZERO_COPY_VERIFICATION.md)
cover the source-to-native-consumer boundary, not arbitrary browser processing.

| Backend | Camera name | Build entry point | Additional requirement |
| --- | --- | --- | --- |
| `NativeCamera` | `Syphon Zero Copy Camera` | `NativeCamera/project.yml` | Apple Developer signing and extension approval |
| Existing `BridgeApp` | `UniCamEx` | Root `project.yml` / `make build` | Separately installed UniCamEx release |

The existing UniCamEx path was also verified on the maintainer's Mac:

- macOS 26.5.1, arm64
- Xcode 26.6
- UniCamEx v1.2.0
- moving diagnostic pattern through the UniCamEx camera
- Webcam Motion Capture's Syphon output through the UniCamEx camera
- QuickTime Player camera preview
- newest-frame-wins queue with effective depth 1

This repository is source-first and experimental; it does not provide a
notarized, pre-signed application for general distribution. NativeCamera has a
separate signing and installation procedure and does not require UniCamEx.

## Native Camera build and use

See [NativeCamera/README.md](NativeCamera/README.md) for prerequisites, team and
identifier configuration, signing, and installation. With the Syphon Release
framework and a valid signing configuration available, build from the repository root:

```sh
xcodegen generate --spec NativeCamera/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project NativeCamera/SyphonZeroCopyCamera.xcodeproj \
  -scheme SyphonZeroCopyCamera -configuration Release \
  -derivedDataPath build/native-camera/DerivedData build
```

On the maintainer's Mac, the installed bundle retains the earlier probe name.
After installation and activation, enable WMC's Syphon output, then start the
default **1080p / 30 fps** stream:

```sh
open -n /Applications/SyphonCameraExtensionProbe.app --args --source syphon
```

Select **Syphon Zero Copy Camera** in the receiving app. For optional 720p,
stop all camera consumers and quit the sender first, then launch with
`--source syphon --resolution 720p`. `--resolution 1080p` explicitly selects the
default. Do not launch multiple sender instances. The GUI also offers the
resolution selector and WMC start/stop controls.

NativeCamera reports missing, ambiguous, or disconnected WMC sources rather
than switching to a diagnostic image. Its host runs outside App Sandbox for
Syphon's dynamic Mach port communication; the extension remains sandboxed and
both targets use Hardened Runtime. See the
[30 fps implementation and operating guide](Docs/NATIVE_CAMERA_30FPS.md).

## UniCamEx requirements

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

## UniCamEx quick start

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

`make build` produces three self-contained app bundles in
`build/Build/Products/Debug/`:

- `SyphonUniCamExBridge.app` — the integrated, single-Mac bridge
- `SyphonUniCamExSender.app` — the network H.264 sender
- `SyphonUniCamExReceiver.app` — the network H.264 receiver and UniCamEx output

Each bundle embeds the required Syphon framework, so it can be copied or moved
as an intact `.app` bundle without its build directory. The integrated bridge
and receiver still require UniCamEx to be installed and approved separately on
the Mac that exposes the virtual camera. Local builds are unsigned; sign and
notarize them before general distribution.

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

## UniCamEx build options

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

## UniCamEx architecture

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

The native WMC comparison kept GPU conversion and output at approximately
30 fps in both resolutions. **Lower CPU load from 720p was not confirmed.**
The host's GPU conversion command time fell by about **21.8%**, and its physical
footprint fell by about **8.22 MiB**. These are host measurements, not whole-Mac
GPU utilization or total system memory savings.

A separate Meet network observation confirmed **1080p camera input → 720p
transmission and reception at approximately 30 fps**. The 720p-input network
comparison and alignment of RTP statistics with the CPU comparison windows
remain incomplete; a reduction in actual network load has not been established.
See [the measured results and limits](Docs/NATIVE_CAMERA_MEET_PERFORMANCE.md).
1080p remains the default, with 720p available as an option.

The historical UniCamEx reference run measured approximately 16.8–18.8% bridge CPU,
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

- [`NativeCamera/README.md`](NativeCamera/README.md) — native extension build, signing, installation, and ownership contract
- [`Docs/NATIVE_CAMERA_30FPS.md`](Docs/NATIVE_CAMERA_30FPS.md) — WMC input, default 1080p and optional 720p at 30 fps
- [`Docs/NATIVE_CAMERA_MEET_PERFORMANCE.md`](Docs/NATIVE_CAMERA_MEET_PERFORMANCE.md) — resolution comparison and actual Meet transmission evidence
- [`Docs/NATIVE_ZERO_COPY_PERFORMANCE.md`](Docs/NATIVE_ZERO_COPY_PERFORMANCE.md) — separate diagnostic-source copy/no-copy benchmark
- [`Docs/ZERO_COPY_AUDIT.md`](Docs/ZERO_COPY_AUDIT.md) — copy boundaries and upstream limitations
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
