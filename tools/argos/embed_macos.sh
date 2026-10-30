#!/bin/bash
set -euo pipefail
root="$(cd "$PROJECT_DIR/.." && pwd)"
helper="$root/build/argos-helper"
if [[ ! -x "$helper/screenclip_argos" || "$root/tools/argos/worker.py" -nt "$helper/screenclip_argos" || "$root/tools/argos/requirements.txt" -nt "$helper/screenclip_argos" || "$root/tools/argos/build.py" -nt "$helper/screenclip_argos" ]]; then
  python="${ARGOS_BUILD_PYTHON:-python3}"
  if [[ -x "$root/build/argos-venv-$(uname -m)/bin/python" ]]; then
    python="$root/build/argos-venv-$(uname -m)/bin/python"
  fi
  "$python" "$root/tools/argos/build.py" --destination "$helper"
fi
destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/argos"
python3 - "$destination" <<'PY'
from pathlib import Path
import shutil
import sys
path = Path(sys.argv[1])
if path.exists():
    shutil.rmtree(path)
PY
mkdir -p "$destination"
ditto "$helper" "$destination"
resources="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/argos"
mkdir -p "$resources"
# Helpers is a code-only signing location. Python metadata belongs in Resources.
python3 - "$destination/_internal" "$resources/_internal" <<'PY'
from pathlib import Path
import shutil
import sys
source, target = map(Path, sys.argv[1:])
if target.exists():
    shutil.rmtree(target)
shutil.move(str(source), str(target))
for name in ['licenses', 'NOTICE.md']:
    item = source.parent / name
    output = target.parent / name
    if output.is_dir():
        shutil.rmtree(output)
    elif output.exists():
        output.unlink()
    if item.exists():
        shutil.move(str(item), str(output))
PY
ln -s ../../Resources/argos/_internal "$destination/_internal"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
  --entitlements "$PROJECT_DIR/Runner/ArgosHelper.entitlements" "$destination/screenclip_argos"
