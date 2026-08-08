#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required: brew install xcodegen" >&2
  exit 1
fi

if grep -q 'YOURTEAMID' project.yml; then
  echo "Edit DEVELOPMENT_TEAM in project.yml before signing." >&2
fi

xcodegen generate
echo "Generated SyphonCamera.xcodeproj"
echo "Open it with: open SyphonCamera.xcodeproj"
