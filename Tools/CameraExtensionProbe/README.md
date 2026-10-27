# Camera Extension probe

This is the historical signing/activation probe. The current
[NativeCamera backend](../../NativeCamera/README.md) uses the same bundle IDs
and installation path; installing this probe would replace that implementation.
See the [probe results](../../Docs/CAMERA_EXTENSION_PROBE.md) for its original scope.

This isolated probe checks development signing and activation using Dream Jack Inc.
(`85LT3DSJ3L`). It does not integrate with or replace UniCamEx, OBS, or the bridge.

The extension source is adapted from the Camera Extension Swift project template
shipped with the installed Xcode. It exposes **Dream Jack Camera Probe** at
640×480 / 30 fps with a moving white stripe. This diagnostic pattern uses CPU
writes and makes no zero-copy performance claim.

Identifiers:

- Host: `com.dream-jack.syphoncamera.probe`
- Extension: `com.dream-jack.syphoncamera.probe.camera`
- App Group: `85LT3DSJ3L.com.dream-jack.syphoncamera.probe`

Generate and compile without provisioning:

```sh
cd Tools/CameraExtensionProbe
xcodegen generate
xcodebuild -project CameraExtensionProbe.xcodeproj -scheme CameraExtensionProbe \
  -configuration Debug -derivedDataPath build/unsigned \
  CODE_SIGNING_ALLOWED=NO build
```

A signing build requires this team's valid development certificate and macOS
profiles. `-allowProvisioningUpdates` permits Xcode to create the required
identifiers and development profiles in the selected team:

```sh
xcodebuild -project CameraExtensionProbe.xcodeproj -scheme CameraExtensionProbe \
  -configuration Debug -derivedDataPath build/signed \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=85LT3DSJ3L build
```

Install the resulting whole app bundle in `/Applications` before requesting
activation. The host has Activate and Deactivate buttons. Passing `--activate`
or `--deactivate` when launching the host also submits the corresponding request.
The host displays the full log path, request errors and approval/reboot outcomes.
Successful request completion must be checked separately against
`systemextensionsctl list` and camera capture; a request callback alone does not
prove working video.

No security-policy relaxation (SIP or system-extension developer mode) is part of
this probe. The parent app and extension share the company team and App Group.
