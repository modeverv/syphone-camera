# Build and run notes

## Assumptions

- macOS target machine with Xcode installed
- Webcam Motion Capture already working
- Syphon framework/API available to the bridge app
- UniCamEx installed from release on the target Mac

## Bootstrap

```bash
./scripts/bootstrap.sh
```

This script:
- clones UniCamEx upstream as a reference checkout
- optionally clones a Syphon reference checkout
- prints the next steps

## Generate project

The skeleton uses XcodeGen.

```bash
xcodegen generate
```

## Build

```bash
./scripts/build.sh
```

## First runtime test

1. Install and launch UniCamEx if needed.
2. Build and run `SyphonUniCamExBridge`.
3. Use the default test pattern source.
4. Open QuickTime Player -> New Movie Recording.
5. Select the `UniCamEx` camera.
6. Confirm that the moving test pattern is visible.
7. Then test Chrome / Google Meet.

## Second runtime test

1. Launch Webcam Motion Capture and enable Syphon output.
2. In the bridge app, switch source from Test Pattern to Syphon.
3. Confirm frames appear through the `UniCamEx` camera.
4. Then test Chrome / Google Meet.

## Build caveat

The included Swift sources are a scaffold for Codex. Actual import/module names and a few API signatures will likely need adjustment based on the concrete UniCamEx and Syphon checkouts on the target Mac.
