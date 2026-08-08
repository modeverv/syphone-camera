# Build and Signing

Camera Extensions are System Extensions.

## Identifiers

Example:

```text
App:       com.example.SyphonCamera
Extension: com.example.SyphonCamera.CameraExtension
App Group: group.com.example.SyphonCamera
```

Replace these consistently in:

- `project.yml`
- `Shared/CameraConstants.swift`
- app entitlements
- extension entitlements

## Capabilities

Host app:

- System Extension
- App Groups
- App Sandbox

Camera Extension:

- App Groups
- App Sandbox

## Install location

For activation testing, the containing app must be installed under `/Applications`.

Typical development flow:

```bash
xcodegen generate
xcodebuild \
  -project SyphonCamera.xcodeproj \
  -scheme SyphonCameraApp \
  -configuration Debug \
  build
```

Then copy the produced `.app` to `/Applications` and launch that copy.

Do not diagnose activation while launching a DerivedData copy from an arbitrary path.

## Approval

The first activation may require approval in System Settings.

After code changes to the extension:
- increment build if needed
- rebuild/copy app
- activation delegate returns `.replace` for an installed prior version

## Reset during development

If the system gets into a stale extension state, use Apple's `systemextensionsctl` tooling only as needed and prefer normal deactivate/activate first.

Codex should capture the exact current macOS commands in `Docs/IMPLEMENTATION_NOTES.md` instead of hard-coding possibly obsolete reset procedures here.
