#!/bin/bash
set -euo pipefail
ipa=${1:?Usage: validate-ipa.sh file.ipa [expected-bundle-id]}
bundle=${2:-${FRAMEFLOW_BUNDLE_ID:-com.frameflow.app}}
[[ -s "$ipa" ]] || { echo "Missing or empty IPA: $ipa" >&2; exit 1; }
unzip -tq "$ipa"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Check paths and link targets before extraction, including paths below symlinks.
python3 - "$ipa" <<'PY'
import posixpath, stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    seen, links = set(), set()
    for member in z.infolist():
        path = member.filename.rstrip("/")
        if path != posixpath.normpath(path) or not (path in {"Payload", "Payload/FrameFlow.app"} or path.startswith("Payload/FrameFlow.app/")) or path in seen:
            sys.exit("Unexpected archive member: " + path)
        seen.add(path)
        if stat.S_ISLNK(member.external_attr >> 16):
            link = z.read(member).decode()
            target = posixpath.normpath(posixpath.join(posixpath.dirname(path), link))
            if link.startswith("/") or not target.startswith("Payload/FrameFlow.app/"):
                sys.exit("External symbolic link: " + path)
            links.add(path)
    if any(any(p.startswith(link + "/") for link in links) for p in seen):
        sys.exit("Unexpected entry below a symbolic link")
    if "Payload/FrameFlow.app/Info.plist" not in seen:
        sys.exit("Missing application plist")
PY
/usr/bin/ditto -x -k "$ipa" "$tmp"
app="$tmp/Payload/FrameFlow.app"
info="$app/Info.plist"
plutil -lint "$info"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$info"; }
[[ "$(read_key CFBundleIdentifier)" == "$bundle" ]]
[[ "$(read_key CFBundlePackageType)" == APPL ]]
[[ "$(read_key CFBundleSupportedPlatforms:0)" == iPhoneOS ]]
[[ "$(read_key DTPlatformName)" == iphoneos ]]
exe=$(read_key CFBundleExecutable)
[[ -n "$exe" && "$exe" != */* && -f "$app/$exe" && -x "$app/$exe" ]]
xcrun otool -arch arm64 -hv "$app/$exe" | grep -qw EXECUTE
[[ "$(xcrun lipo -archs "$app/$exe")" == arm64 ]]
count=0
while IFS= read -r -d '' item; do
    if file -b "$item" | grep -q 'Mach-O'; then
        [[ "$(xcrun lipo -archs "$item")" == arm64 ]]
        xcrun vtool -arch arm64 -show-build "$item" | grep -Eq '^[[:space:]]*platform[[:space:]]+IOS[[:space:]]*$'
        if codesign -d "$item" >/dev/null 2>&1; then
            echo "Unexpected signature: $item" >&2; exit 1
        fi
        count=$((count+1))
    fi
done < <(find "$app" -type f -print0)
[[ $count -gt 0 ]]
[[ -z "$(find "$app" \( -name embedded.mobileprovision -o -name _CodeSignature \) -print)" ]]
echo "Validated $bundle ($exe), $count unsigned iPhoneOS arm64 Mach-O file(s)."
