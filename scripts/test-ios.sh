#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs
xcodebuild -project FrameFlow.xcodeproj -scheme FrameFlow -showdestinations > build/logs/destinations.txt
xcrun simctl list -j devices available > build/logs/devices.json
device=$(python3 - <<'PY'
import json,re
from pathlib import Path
available=[]
for runtime,devices in json.loads(Path("build/logs/devices.json").read_text())["devices"].items():
    version=re.search(r"iOS-(\d+)(?:-(\d+))?(?:-(\d+))?$",runtime)
    if not version or int(version[1]) < 18:
        continue
    for d in devices:
        if d["name"].startswith("iPhone") and d["isAvailable"]:
            available.append(("Duo" in d["name"], tuple(int(n or 0) for n in version.groups()),d["udid"]))
if not available:
    raise SystemExit("No compatible iPhone simulator. See destinations.txt and devices.json.")
print(max(available)[2])
PY
)
xcrun simctl bootstatus "$device" -b
result=$(mktemp -d "$PWD/build/logs/test.XXXXXX")/Tests.xcresult
xcodebuild test -sdk iphonesimulator -project FrameFlow.xcodeproj -scheme FrameFlow -configuration Debug \
    -destination "platform=iOS Simulator,id=$device" -derivedDataPath build/TestDerived \
    -parallel-testing-enabled NO -resultBundlePath "$result" 2>&1 | tee build/logs/tests.log
