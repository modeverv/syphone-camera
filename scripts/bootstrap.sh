#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
mkdir -p "$VENDOR"

clone_or_update() {
  local repo_url="$1"
  local dest="$2"
  if [[ -d "$dest/.git" ]]; then
    echo "Updating $(basename "$dest")..."
    git -C "$dest" pull --ff-only || true
  else
    echo "Cloning $repo_url ..."
    git clone "$repo_url" "$dest" || true
  fi
}

clone_or_update "https://github.com/creativeIKEP/UniCamEx.git" "$VENDOR/UniCamEx"
clone_or_update "https://github.com/Syphon/Syphon-Framework.git" "$VENDOR/Syphon-Framework"

echo
echo "Bootstrap complete."
echo "Next steps:"
echo "  1. Install UniCamEx release on this Mac if not already installed."
echo "  2. Verify the UniCamEx camera appears in QuickTime."
echo "  3. Read Docs/CODEX_HANDOFF.md and use it as the work order."
