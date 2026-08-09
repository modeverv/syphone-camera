#!/usr/bin/env bash
set -euo pipefail

echo "== macOS =="
sw_vers
echo

echo "== architecture =="
uname -m
echo

echo "== Xcode =="
xcodebuild -version || true
echo

echo "== UniCamEx camera reminder =="
echo "Open QuickTime Player -> New Movie Recording and verify that 'UniCamEx' appears as a camera source."
