#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
framework_dir="$repo_root/Vendor/Syphon-Framework/DerivedData/Build/Products/Release"
output_dir="$repo_root/Tools/ZeroCopyDiagnostics/build"
mkdir -p "$output_dir"

if [[ ! -d "$framework_dir/Syphon.framework" ]]; then
    print -u2 "Build the vendored Syphon Release framework first: $framework_dir/Syphon.framework"
    exit 1
fi

xcrun swiftc -swift-version 5 \
    -F "$framework_dir" \
    -framework Syphon -framework AppKit -framework Metal \
    -framework CoreVideo -framework CoreMedia -framework IOSurface \
    -Xlinker -rpath -Xlinker "$framework_dir" \
    "$repo_root/Tools/ZeroCopyDiagnostics/surface-wrap-probe.swift" \
    -o "$output_dir/surface-wrap-probe"
print "$output_dir/surface-wrap-probe"
