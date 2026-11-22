#!/usr/bin/env python3
"""Pick an installed production Xcode with Swift 6 and iPhoneOS SDK >= 18."""
import os
import re
import subprocess
import sys
from pathlib import Path

candidates = []
for app in sorted(set(p.resolve() for p in Path("/Applications").glob("Xcode*.app"))):
    if re.search(r"beta|preview|candidate|[_ -]rc", app.name, re.I):
        print(f"Skip prerelease {app}", flush=True)
        continue
    developer = app / "Contents/Developer"
    env = dict(os.environ, DEVELOPER_DIR=str(developer))
    try:
        version = subprocess.check_output(["xcodebuild", "-version"], text=True, env=env)
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], text=True, env=env).strip()
        swift = subprocess.check_output(["xcrun", "swiftc", "--version"], text=True, env=env)
    except subprocess.CalledProcessError:
        continue
    print(f"{app}: {version.strip()}, iPhoneOS {sdk}, {swift.splitlines()[0]}", flush=True)
    match = re.search(r"^Xcode (\d+(?:\.\d+)*)$", version, re.M)
    if match and int(sdk.split(".")[0]) >= 18 and re.search(r"Swift version (?:[6-9]|[1-9]\d+)\.", swift):
        candidates.append((tuple(map(int, match[1].split("."))), developer))

if not candidates:
    sys.exit("Install a stable Xcode 16+ with iPhoneOS SDK 18+.")
developer = str(max(candidates)[1])
print(f"Selected {developer}", flush=True)
env = dict(os.environ, DEVELOPER_DIR=developer)
subprocess.run(["xcodebuild", "-showsdks"], check=True, env=env)
if "GITHUB_ENV" in os.environ:
    with open(os.environ["GITHUB_ENV"], "a") as f:
        print("DEVELOPER_DIR=" + developer, file=f)
