#!/bin/bash
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
app=${1:?Usage: package-ipa.sh /path/to/FrameFlow.app [output.ipa]}
out=${2:-build/dist/FrameFlow-unsigned.ipa}
[[ "$(basename "$app")" == FrameFlow.app && -f "$app/Info.plist" ]]
mkdir -p "$(dirname "$out")"
outdir=$(cd "$(dirname "$out")" && pwd)
stage=$(mktemp -d "$outdir/.package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Payload"
/usr/bin/ditto --norsrc --noextattr --noqtn "$app" "$stage/Payload/FrameFlow.app"
# A linker can attach an ad-hoc signature even when Xcode signing is disabled.
while IFS= read -r -d '' item; do
    if file -b "$item" | grep -q 'Mach-O' && codesign -d "$item" >/dev/null 2>&1; then
        codesign --remove-signature "$item"
    fi
done < <(find "$stage/Payload" -type f -print0)
(cd "$stage" && /usr/bin/zip -q -r -y candidate.ipa Payload)
"$scripts/validate-ipa.sh" "$stage/candidate.ipa"
mv -f "$stage/candidate.ipa" "$out"
