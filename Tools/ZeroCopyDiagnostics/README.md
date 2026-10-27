# Syphon direct-buffer diagnostic findings

Observed on 2026-10-27, macOS 27.0.1 (26A434). These diagnostics establish
why the installed Webcam Motion Receiver cannot currently feed an asynchronous
Camera Extension safely through a direct IOSurface wrap. They do not implement
or claim a working zero-copy WMC pipeline.

The implemented stock-WMC route instead performs one GPU transformation into
an owned output buffer; see [Native Camera operation](../../Docs/NATIVE_CAMERA_30FPS.md).
That working route does not change the direct-wrap limitations documented here.

## Reproduce

Build the vendored Syphon Release framework, then run from the repository root:

```sh
zsh Tools/ZeroCopyDiagnostics/build.sh
Tools/ZeroCopyDiagnostics/build/surface-wrap-probe --synthetic-only
Tools/ZeroCopyDiagnostics/build/surface-wrap-probe
```

The full probe discovers existing Syphon servers for two seconds, subscribes
for five seconds, tests public CoreVideo wrapping, and retains the first texture
throughout that observation window. It does not start a physical camera, map or
read image pixels, or alter the publisher. Output is JSON Lines. Receiver must
already be running with Syphon enabled for a live result.

The checked-in [observed output](evidence/wmc-retained-surface-2026-10-27.jsonl)
contains metadata only. Surface IDs and seeds are observations from this run,
not stable identifiers to use in application logic.

## CoreVideo wrapping: current live evidence

| Input | IOSurface pixel format | Wrap result |
| --- | --- | --- |
| Synthetic 640 x 480, no format property | 0 | -6680 for every attribute variant |
| Synthetic 640 x 480, explicit BGRA surface property | BGRA | Success; same IOSurface ID; valid CMVideoFormatDescription |
| Live WMC 1920 x 1080 | 0 | -6680 for every attribute variant |

Tested attribute dictionaries are `nil`, explicit BGRA, explicit BGRA with
dimensions, Metal compatibility, and explicit BGRA with Metal compatibility.
In this run, WMC's MTLTexture reports `bgra8Unorm` (80), but its backing IOSurface
reports pixel format 0, 4 bytes per element, stride 7680, allocation 8306688.
Texture interpretation does not supply the missing IOSurface creation property.
Wrapper attributes do not repair it.

The SDK defines -6680 as `kCVReturnInvalidPixelFormat`; -6661 is
`kCVReturnInvalidArgument`. Earlier project notes reported -6661. This probe
reproduces -6680, so it does **not** establish the exact cause of the historical
-6661 call. `IOSurfaceSetValue` attaches metadata; it cannot change the
underlying IOSurface pixel-format property after allocation.

## Holding the texture does not hold an immutable frame

The probe held the first received WMC MTLTexture continuously while receiving
150 frame notifications over five seconds:

- All 150 frames referenced IOSurface ID 934.
- The retained surface seed changed from 9508 to 9657.
- Its allocation remained alive, but the producer continued updating it.

This is live evidence that retaining `SyphonMetalClient.newFrameImage()` is
not an immutable frame lease. Passing that same storage to an asynchronous
camera consumer permits later producer writes to affect an earlier frame.

The vendored Syphon implementation agrees with this observation:

- `SyphonServerBase.newSurfaceForWidth:height:options:` keeps one surface until
  dimensions change, and sends its ID to clients.
- `SyphonMetalServer` caches a texture backed by that surface and writes each
  publication into it.
- `SyphonClientConnectionManager` obtains the surface using `IOSurfaceLookup`.
  Retaining that object keeps storage alive; it does not stop producer writes.
- The server has no consumer release acknowledgement or `IOSurfaceIsInUse`
  pool-reuse check. The Metal client header explicitly allows the returned
  texture to continue updating.

Consequently a format-only WMC plugin change would remove one compatibility
obstacle while leaving the frame-ownership obstacle unresolved.

## Installed WMC plugin and native replacement feasibility

Inspected without editing the original app:

```text
/Applications/WebcamMotionCapture_JA/Webcam Motion Receiver.app
CFBundleIdentifier: info.kwcl.WebcamMotionReceiver
CFBundleShortVersionString: 0.1
Contents/PlugIns/KlakSyphon.bundle: universal Mach-O library, not a bundle directory
SHA-256: 8b29f2c9a9d2c06eb4cac9aa05e7cfb3fecdeb40721e918e43ee4ebeb28149ee
```

The app contains `Resources/Data/il2cpp_data/Metadata/global-metadata.dat` and
has no managed Klak Syphon DLL available for replacement. Native arm64
disassembly confirms `Plugin_GetServerTexture` forwards to the `texture`
selector and `Plugin_PublishServerTexture` forwards to `publishNewFrame`.
It exports the standard KlakSyphon server/client API.

Compared upstream KlakSyphon sources:

- Tag 1.0.0: `dc5305d0bf8707b7c0199a386dec59b9bf632f71`
- Checked-out current revision: `4fb4be62fe23b1fddc8f8c66ab34ce5bf3607c47`

Both versions' managed `PluginServer.CreateWithBackedTexture` obtain
`Plugin_GetServerTexture` once and construct `Texture2D.CreateExternalTexture`.
The capture coroutine repeatedly writes to that cached texture and calls
`PublishTexture`; it does not reacquire the native texture each frame. Therefore
rotating an IOSurface ring inside the native plugin alone would leave Unity
rendering into its old cached target. This conclusion is based on upstream
managed source and the installed native ABI; the shipped IL2CPP managed caller
was not decompiled or patched.

Old `LiteServer` creates one IOSurface without `kIOSurfacePixelFormat`, matching
the installed producer's observed format-0 output. Current upstream adds BGRA,
but still uses a single surface. Neither version supplies a safe immutable
ring contract for camera consumers.

An isolated app copy would protect the original, but does not by itself solve
these ABI and IL2CPP issues. No replacement plugin or binary patch was installed.
A fixed single buffer that blocks until all camera consumers release it is not
a sound substitute: consumers can retain the last frame pending the next one,
creating an unbounded wait or deadlock.

## Copy boundary, orientation, and GPU completion

Both inspected upstream versions' `Blitter` perform
`Graphics.Blit(source, temporaryRenderTexture)` followed by
`Graphics.CopyTexture(temporaryRenderTexture, externalTexture)`. The command
buffer overload does the equivalent two operations. GameView capture also
captures the screen into a temporary render texture. Thus even adding per-frame
`UpdateExternalTexture` and a pool would not remove these existing producer
operations; it would only address the later transport boundary.

GameView passes `vflip: true`; its shader flips the sampling UV. Texture and
camera paths use the default false value. The actual installed WMC capture mode
and final visual orientation were not established by these metadata diagnostics.
Correct orientation must be chosen in the original rendering operation if an
additional transform pass is to be avoided.

The inspected `Plugin_PublishServerTexture` / `LiteServer.publishNewFrame`
only send a notification, with no GPU-completed handler. A managed coroutine
call after issuing draw commands is not proof those commands finished on the
GPU. Unity documents that rendering commands may execute on a separate render
thread. A producer integration needs a correctly ordered rendering-thread hook
and GPU completion before handing the immutable frame to the camera transport.

## Required producer integration contract

For a future WMC source integration or another controlled native producer:

1. Acquire a writable IOSurface-backed CVPixelBuffer from a bounded pool with
   explicit BGRA format and matching size. Exhaustion must drop/backpressure;
   it must never overwrite an in-flight frame.
2. Render the final image directly into that buffer's Metal texture, with final
   orientation and color interpretation. If a separate source image is copied
   into it, describe that earlier copy boundary honestly.
3. After the rendering command buffer completes successfully, transfer the
   pixel buffer to the native camera sink. The producer must cease all writes.
4. Keep ownership through transport and downstream consumers, then return it
   for reuse only when those owners release it. Use the CoreVideo/IOSurface
   sharing and pool contract, including Mach-port references for cross-process
   sharing; a bare numeric IOSurface ID or server-description boolean is not
   a lease. An atomic acquisition/reuse protocol is necessary.
5. Validate identical IOSurface IDs at source, extension input/output, and
   consumer, plus retained-buffer stress and frame correctness. An ID match
   alone does not demonstrate safe lifetime or correct pixels.

## Primary references

- [KlakSyphon 1.0.0 PluginServer.cs](https://github.com/keijiro/KlakSyphon/blob/dc5305d0bf8707b7c0199a386dec59b9bf632f71/jp.keijiro.klak.syphon/Runtime/Interop/PluginServer.cs)
- [KlakSyphon 1.0.0 SyphonServer.cs](https://github.com/keijiro/KlakSyphon/blob/dc5305d0bf8707b7c0199a386dec59b9bf632f71/jp.keijiro.klak.syphon/Runtime/SyphonServer.cs)
- [KlakSyphon 1.0.0 Blitter](https://github.com/keijiro/KlakSyphon/blob/dc5305d0bf8707b7c0199a386dec59b9bf632f71/jp.keijiro.klak.syphon/Runtime/Internal/Utility.cs)
- [KlakSyphon 1.0.0 LiteServer](https://github.com/keijiro/KlakSyphon/blob/dc5305d0bf8707b7c0199a386dec59b9bf632f71/Plugin/LiteServer.m)
- [KlakSyphon current LiteServer at inspected revision](https://github.com/keijiro/KlakSyphon/blob/4fb4be62fe23b1fddc8f8c66ab34ce5bf3607c47/Plugin/LiteServer.m)
- [Unity native rendering-thread callbacks](https://docs.unity3d.com/Manual/low-level-native-plugin-rendering-extensions.html)
- [Apple CVPixelBufferCreateWithIOSurface](https://developer.apple.com/documentation/corevideo/cvpixelbuffercreatewithiosurface(_:_:_:_:))
- Local SDK `IOSurface.framework/Headers/IOSurfaceRef.h`: value attachments,
  Mach-port implicit use counts, `IOSurfaceIsInUse` and pooling contract.
- Local SDK `CoreVideo.framework/Headers/CVReturn.h`: exact error constants.
