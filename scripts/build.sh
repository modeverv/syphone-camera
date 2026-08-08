#!/usr/bin/env bash
set -euo pipefail

xcodegen generate
xcodebuild \
  -project SyphonCamera.xcodeproj \
  -scheme SyphonCameraApp \
  -configuration Debug \
  build
