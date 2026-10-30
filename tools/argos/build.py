"""Build on each target OS/architecture. No cross compilation or model bundling."""
import argparse
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import venv

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--destination", type=Path, required=True)
args = parser.parse_args()
env = ROOT / f"build/argos-venv-{platform.machine()}"
# Use the prepared Windows environment when available.
if sys.platform == "win32" and (ROOT / "build/argos-venv").exists():
    env = ROOT / "build/argos-venv"
if not env.exists():
    venv.create(env, with_pip=True)
python = env / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
subprocess.run([str(python), "-m", "pip", "install", "-r", str(ROOT / "tools/argos/requirements.txt")], check=True)
subprocess.run([str(python), "-m", "PyInstaller", "--noconfirm", "--clean", "--onedir",
    "--name", "screenclip_argos", "--distpath", str(ROOT / "build/argos-dist"),
    "--workpath", str(ROOT / "build/argos-pyinstaller"), "--specpath", str(ROOT / "build"),
    "--collect-all", "ctranslate2", "--collect-all", "sentencepiece", "--collect-data", "certifi",
    "--copy-metadata", "ctranslate2", "--copy-metadata", "sentencepiece",
    str(ROOT / "tools/argos/worker.py")], check=True)
source = ROOT / "build/argos-dist/screenclip_argos"
args.destination.mkdir(parents=True, exist_ok=True)
shutil.copytree(source, args.destination, dirs_exist_ok=True)
shutil.copy2(ROOT / "tools/argos/NOTICE.md", args.destination / "NOTICE.md")
# Copy license texts explicitly: metadata files alone may omit wheel licenses.
script = """import importlib.metadata as m, pathlib, shutil, sys
out=pathlib.Path(sys.argv[1])
for package in ['ctranslate2','sentencepiece','numpy','setuptools','pyinstaller','certifi']:
 d=m.distribution(package)
 for item in d.files or []:
  if any(v in str(item).lower() for v in ['license','copying','notice']):
   source=pathlib.Path(d.locate_file(item))
   if source.is_file():
    target=out/package/pathlib.Path(str(item)).name
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(source,target)
"""
subprocess.run([str(python), '-c', script, str(args.destination / 'licenses')], check=True)
print("Argos helper:", args.destination)
