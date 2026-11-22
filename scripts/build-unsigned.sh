#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export FRAMEFLOW_BUNDLE_ID=${FRAMEFLOW_BUNDLE_ID:-com.frameflow.app}
mkdir -p build/logs build/dist
args=(-project FrameFlow.xcodeproj -scheme FrameFlow -derivedDataPath "$PWD/build/DeviceDerived")
xcodebuild "${args[@]}" -resolvePackageDependencies 2>&1 | tee build/logs/resolve.log
xcodebuild build "${args[@]}" -sdk iphoneos -configuration Release -destination 'generic/platform=iOS' \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO "FRAMEFLOW_BUNDLE_ID=$FRAMEFLOW_BUNDLE_ID" \
    2>&1 | tee build/logs/device.log
app="$PWD/build/DeviceDerived/Build/Products/Release-iphoneos/FrameFlow.app"
ipa=build/dist/FrameFlow-unsigned.ipa
scripts/package-ipa.sh "$app" "$ipa" 2>&1 | tee build/logs/package.log
(cd build/dist && shasum -a 256 FrameFlow-unsigned.ipa > checksums.txt && shasum -a 256 -c checksums.txt)
sha=${GITHUB_SHA:-$(git rev-parse HEAD)}
{
    echo "Git commit SHA: $sha"
    echo "Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")"
    echo "Build number: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")"
    xcodebuild -version
    echo "iOS SDK: $(xcrun --sdk iphoneos --show-sdk-version)"
    echo "UTC build time: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "Target: generic/platform=iOS | iphoneos | Release | arm64 | $FRAMEFLOW_BUNDLE_ID"
    echo "Signing: unsigned (CODE_SIGNING_ALLOWED=NO)"
} > build/dist/build-info.txt
