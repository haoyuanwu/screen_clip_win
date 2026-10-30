#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?Usage: tools/package_macos.sh VERSION [arm64|x64|all]}"
target="${2:-all}"
if [[ "$target" == all ]]; then
  "$0" "$version" arm64
  "$0" "$version" x64
  (cd "$root/dist" && shasum -a 256 "ScreenClip-$version-macOS-arm64.dmg" "ScreenClip-$version-macOS-x64.dmg" > "SHA256SUMS-$version-macOS.txt")
  exit 0
fi
case "$target" in
  arm64) arch=arm64 ;;
  x64) arch=x86_64 ;;
  *) printf 'Unsupported architecture: %s\n' "$target" >&2; exit 1 ;;
esac
source_app="$root/build/macos/Build/Products/Release/screen_clip_win.app"
test -d "$source_app"
mkdir -p "$root/dist"
stage="$(mktemp -d "$root/dist/macos-$version.XXXXXX")"
app="$stage/定格T.app"
ditto "$source_app" "$app"
python3 - "$app" <<'PY'
from pathlib import Path
import shutil
import sys
app = Path(sys.argv[1])
for relative in ['Contents/Helpers/argos', 'Contents/Resources/argos']:
    path = app / relative
    if path.exists():
        shutil.rmtree(path)
PY
if [[ "$target" == arm64 ]]; then
  helper_source="${ARGOS_HELPER_ARM64:-}"
else
  helper_source="${ARGOS_HELPER_X64:-}"
fi
if [[ -n "$helper_source" ]]; then
  test -x "$helper_source/screenclip_argos"
  ditto "$helper_source" "$app/Contents/Helpers/argos"
else
  python3 "$root/tools/argos/build.py" --destination "$app/Contents/Helpers/argos"
fi
ln -s /Applications "$stage/Applications"

# Distribution is ad-hoc until a Developer ID identity is configured. Sign
# nested code first; only the outer application receives sandbox entitlements.
python3 - "$app" "$root/macos/Runner/Release.entitlements" "$arch" <<'PY'
from pathlib import Path
import subprocess
import sys
import os

app = Path(sys.argv[1])
# Keep Python data out of the code-only Helpers signing location.
helper_data = app / 'Contents/Resources/argos'
helper_data.mkdir(parents=True, exist_ok=True)
shutil_source = app / 'Contents/Helpers/argos/_internal'
shutil_source.rename(helper_data / '_internal')
shutil_source.symlink_to('../../Resources/argos/_internal')
for name in ['licenses', 'NOTICE.md']:
    source = app / 'Contents/Helpers/argos' / name
    if source.exists():
        source.rename(helper_data / name)
# Thin every Mach-O file, including Flutter, plugins and bundled native libraries.
magics = {b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca',
          b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce'}
native_binaries = []
for item in app.rglob('*'):
    if item.is_symlink() or not item.is_file():
        continue
    with item.open('rb') as source:
        if source.read(4) not in magics:
            continue
    native_binaries.append(item)
    archs = subprocess.check_output(['lipo', '-archs', str(item)], text=True).split()
    if sys.argv[3] not in archs:
        raise RuntimeError(f'{item} does not support {sys.argv[3]}')
    if len(archs) > 1:
        mode = item.stat().st_mode
        output = item.with_name(item.name + '.thin')
        subprocess.run(['lipo', str(item), '-thin', sys.argv[3], '-output', str(output)], check=True)
        os.replace(output, item)
        item.chmod(mode)
nested = native_binaries + list(app.rglob('*.framework'))
for item in sorted(nested, key=lambda p: len(p.parts), reverse=True):
    subprocess.run(['codesign', '--force', '--sign', '-', str(item)], check=True)
# Sandboxed child inherits the parent app's container/network permissions.
helper_entitlements = Path(sys.argv[2]).parent / 'ArgosHelper.entitlements'
helper = app / 'Contents/Helpers/argos/screenclip_argos'
subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(helper_entitlements), str(helper)], check=True)
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
(cd "$root/dist" && shasum -a 256 "$(basename "$dmg")" > "SHA256SUMS-$version-macOS-$platform.txt")
printf 'DMG: %s\nArchitecture: %s\n' "$dmg" "$archs"
