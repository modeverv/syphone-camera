# ADR-001: Network video transport for the remote Syphon input

- Status: accepted for trusted-LAN PoC
- Date: 2026-08-09

## Context

Syphon shares Metal textures only within one Mac. A remote WMC source therefore
needs a sender that captures the Syphon texture, encodes it, and sends a video
stream to this bridge. The receiver must feed the decoded frames through the
existing `FrameSource -> BridgeEngine -> UniCamExSender` path.

## Decision

Use **UDP** for the current trusted-LAN PoC, with a fixed receiver address and
manual configuration. TCP testing showed head-of-line blocking risk and is not
exposed through the separate sender/receiver apps. The production target remains
**WebRTC**, which adds congestion handling, reconnection, and encryption before
any public-network deployment.

The sender contract is:

```text
 SyphonMetalClient -> Metal/VideoToolbox encoder -> fragmented H.264/UDP sender
```

The receiver contract is:

```text
H.264/UDP receiver -> bounded latest-frame buffer (depth 1)
  -> BGRA 1920x1080 30 fps normalization -> NetworkFrameSource
  -> BridgeEngine -> UniCamExSender
```

Audio is out of scope. The receiver discards stale frames, reports sequence /
timestamp gaps, and reconnects after timeout. During disconnection it exposes no
new frame; the existing engine fallback behavior remains authoritative.

## Candidate comparison

| Option | Strength | Cost / risk | MVP decision |
| --- | --- | --- | --- |
| WebRTC | Low latency, congestion control, encryption, reconnection | Larger dependency and signaling surface | Production target |
| SRT/RIST | Robust contribution-video transport | Extra libraries and less direct app integration | Keep as fallback |
| Fragmented H.264/UDP | Minimal latency; newest frame can win after loss | Packet loss, security, pacing, and recovery become ours | **Trusted-LAN PoC** |
| RTSP | Broad tool interoperability | Higher latency and server/client lifecycle overhead | Reject for MVP |

## PoC acceptance measurements

On the same LAN, manually configure a fixed sender and receiver and record
end-to-end latency, sender/receiver CPU, bandwidth, video drops, decode errors,
and reconnect time at 1920x1080/30 fps. Test with both a deterministic test
pattern and a real WMC Syphon source. No result is considered a zero-copy claim:
the complete GPU/encoder/decoder path must be measured.

## Frame contract

- Codec/profile: implementation-defined during PoC; record the negotiated value.
- Pixel format at the bridge boundary: BGRA, 8-bit, premultiplied as required by
  the existing `CVPixelBuffer` / `CMSampleBuffer` path.
- Size: exactly 1920x1080 after receiver normalization.
- Rate: 30 fps target; timestamps use a monotonic timebase and preserve capture
  order. The receiver may drop late frames.
- Orientation: upright, no implicit mirroring.
- Color: carry negotiated metadata where available; normalize to the existing
  sRGB/BGRA path.
- Keyframe interval: record the encoder setting; reconnect must request or wait
  for a decodable keyframe.
- Sequence/timestamp: each frame has a sequence number and capture timestamp;
  gaps and receive/decode latency are instrumented.
- Audio: not transported.

## MVP operational requirements

- macOS 13 or later; Apple Silicon is the primary target, Intel remains a PoC
  compatibility target if the selected WebRTC build supports it.
- Same LAN, manual sender address, and explicitly documented signaling/control
  port plus media ports.
- Authentication/encryption is provided by the selected WebRTC implementation;
  no unauthenticated public-network deployment is supported.
- Firewall permissions and reconnect behavior are documented after the PoC.

## Current PoC limitation

The sender and receiver use VideoToolbox H.264 sessions. The sender uses
`VTCompressionSession` and sends H.264 access units plus SPS/PPS; the receiver
uses `VTDecompressionSession` and exposes decoded BGRA sample buffers to the
existing bridge. UDP port 5001 is the default trusted-LAN transport. Frames are
fragmented into 1,200-byte datagrams and incomplete assemblies expire after one
second. There is no authentication, encryption, FEC/NACK, congestion control,
or adaptive bitrate. Replacing this PoC transport with WebRTC remains required
before public-network use or MVP completion claims.

## Consequences

The transport is isolated behind `NetworkFrameSource`; local Syphon and test
pattern sources remain selectable and do not depend on WebRTC. If the measured
dependency or CPU cost is unacceptable, the frame contract and source boundary
can be retained while replacing only the transport adapter with SRT/RIST.
