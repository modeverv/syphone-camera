#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install it first (e.g. brew install xcodegen)." >&2
  exit 2
fi

xcodegen generate
xcodebuild -project SyphonUniCamExBridge.xcodeproj   -scheme SyphonUniCamExBridge   -configuration Debug   build
