#!/usr/bin/env python3
"""Build a local, ad-hoc-signed verification app without Apple portal changes."""
from pathlib import Path
import os
import platform
import shutil
import subprocess

root = Path(__file__).resolve().parent
developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
swiftc = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk = developer / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if not swiftc.exists() or not sdk.exists():
    swiftc = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip())
    sdk = Path(subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
app = root / "build/ZeroCopyVerifier.app"
binary = app / "Contents/MacOS/ZeroCopyVerifier"
binary.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "Info.plist", app / "Contents/Info.plist")
args = [str(swiftc), "-swift-version", "5", "-O", "-sdk", str(sdk),
        "-target", f"{platform.machine()}-apple-macos13.0", str(root / "main.swift"),
        "-o", str(binary)]
subprocess.run(args, check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
print(app)
