#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?Usage: tools/package_macos.sh VERSION}"
source_app="$root/build/macos/Build/Products/Release/screen_clip_win.app"
test -d "$source_app"
mkdir -p "$root/dist"
stage="$(mktemp -d "$root/dist/macos-$version.XXXXXX")"
app="$stage/定格T.app"
ditto "$source_app" "$app"
ln -s /Applications "$stage/Applications"

# Distribution is ad-hoc until a Developer ID identity is configured. Sign
# nested code first; only the outer application receives sandbox entitlements.
python3 - "$app" "$root/macos/Runner/Release.entitlements" <<'PY'
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1])
nested = list(app.rglob('*.dylib')) + list(app.rglob('*.framework'))
for item in sorted(nested, key=lambda p: len(p.parts), reverse=True):
    subprocess.run(['codesign', '--force', '--sign', '-', str(item)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', sys.argv[2], str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
PY

archs="$(lipo -archs "$app/Contents/MacOS/screen_clip_win")"
if [[ "$archs" == *arm64* && "$archs" == *x86_64* ]]; then
  platform="Universal"
elif [[ "$archs" == *arm64* ]]; then
  platform="arm64"
else
  platform="x64"
fi
dmg="$root/dist/ScreenClip-$version-macOS-$platform.dmg"
test ! -e "$dmg"
hdiutil create -volname "定格T $version" -srcfolder "$stage" -format UDZO -ov "$dmg"
hdiutil verify "$dmg"
(cd "$root/dist" && shasum -a 256 "$(basename "$dmg")" > "SHA256SUMS-$version-macOS.txt")
printf 'DMG: %s\nArchitecture: %s\n' "$dmg" "$archs"
