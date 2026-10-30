"""Cache and embed the native Windows helper for flutter run/build."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--destination', required=True, type=Path)
args = parser.parse_args()
cache = ROOT / 'build/argos-helper-windows'
helper = cache / 'screenclip_argos.exe'
inputs = [ROOT / 'tools/argos' / name for name in ['worker.py', 'build.py', 'requirements.txt', 'NOTICE.md']]
if not helper.exists() or any(p.stat().st_mtime > helper.stat().st_mtime for p in inputs):
    subprocess.run([sys.executable, str(ROOT / 'tools/argos/build.py'), '--destination', str(cache)], check=True)
shutil.copytree(cache, args.destination, dirs_exist_ok=True)
if not (args.destination / '_internal/certifi/cacert.pem').is_file():
    raise RuntimeError('Bundled HTTPS root certificates are missing')
print('Embedded Windows Argos helper:', args.destination)
